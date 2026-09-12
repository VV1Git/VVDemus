import AppKit
import ScreenCaptureKit

/// Keeps the miniplayer's appearance matched to whatever is actually behind it on screen.
///
/// Everything else in this app decides light-or-dark from the *appearance* — the system setting,
/// or a `preferredColorScheme` pinned by a scene. That is the right answer for a normal window and
/// the wrong one for a floating panel: a Mac set to Dark Mode with a white document open behind
/// the panel gets a dark sheet with white labels sitting on white, and no appearance-based rule
/// can see that, because the thing behind the window is another app's window rather than the
/// desktop or the system setting.
///
/// So it is measured. A tiny screenshot of the region the panel occupies — with the panel itself
/// excluded, or it would read its own glass and latch — averaged to one luminance figure, which
/// picks `aqua` or `darkAqua` for the window. Setting the *appearance* rather than recolouring
/// labels one at a time is what makes `LyricsView` come along too: its lines are `.primary` and
/// `.secondary` like everything else, and they resolve against whatever appearance their window
/// carries.
///
/// This is the one thing in the app that needs Screen Recording permission. It is asked for
/// lazily — nothing here runs until the miniplayer is opened — and a refusal is not an error
/// state: the sampler stops, the window keeps the system appearance, and the panel behaves
/// exactly as it did before this file existed.
///
/// ## Cost
///
/// A screen capture on a repeating timer is a real battery cost, so this one is arranged to run as
/// close to never as it can while still being right:
///
/// - **Events do most of the work.** What is behind the panel changes when you move it, switch
///   app, or resize it — all of which are announced, and none of which needs polling to notice.
/// - **The heartbeat is slow**, and exists only for the changes nothing announces: a page
///   scrolling, a video playing, a document repainting behind the panel.
/// - **Nothing runs while the panel is not on screen.** Occluded, minimised, or on another Space,
///   the sampler is idle — which is most of the time for a window that lives in a corner.
/// - **Each grab is 16×16.** The question is "broadly light or broadly dark", and that is the
///   cheapest image that can answer it.
@MainActor
final class MiniPlayerBackdrop: ObservableObject {
    /// Shared, so the view can observe the same instance the window configurator drives. The
    /// configurator is the only thing that has an `NSWindow`; the view is the only thing that can
    /// re-render. They have to be looking at one object.
    static let shared = MiniPlayerBackdrop()

    private weak var window: NSWindow?
    private var heartbeat: Task<Void, Never>?
    private var debounce: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    /// Latched so a refusal costs one prompt rather than one per interval, forever.
    private var isUnavailable = false

    /// The last decision, kept so an unchanged reading does no work.
    ///
    /// `@Published` because setting `NSWindow.appearance` is not, on its own, enough to move
    /// SwiftUI: the scene resolves its own `colorScheme`, and a window appearance assigned from
    /// outside it can leave the view hierarchy rendering exactly as it did before — a correct
    /// measurement, a correct write, and no visible change. The view drives
    /// `preferredColorScheme` off this, which SwiftUI cannot ignore.
    @Published private(set) var isLight: Bool?

    /// The catch-all interval, for backdrop changes that raise no notification.
    ///
    /// This is doing more work than "catch-all" suggests, which is why it is under a second rather
    /// than the five it started at. Switching *browser tabs* — the case this was actually tripping
    /// over — changes the entire backdrop and announces nothing: the app does not activate, no
    /// window moves, no window resizes. There is no event to hook, so the poll is the only thing
    /// that will ever notice, and at five seconds the panel sat visibly wrong for whole seconds
    /// after the page behind it turned white.
    ///
    /// The cost of going faster is small and was measured rather than assumed — see the note on
    /// `sampleSide`. Each tick is one 16×16 grab of a region a few hundred points across, and the
    /// occlusion guard means it does not run at all unless the panel is genuinely on screen.
    private static let heartbeatInterval: Duration = .milliseconds(750)

    /// Events arrive in bursts — dragging a window emits a stream of `didMove` — so a trigger
    /// waits this long for the burst to end rather than capturing per event.
    private static let settle: Duration = .milliseconds(350)

    /// Deliberately not one threshold.
    ///
    /// A single cut point makes the panel flicker between appearances whenever the backdrop sits
    /// near it — scrolling a page of black text on white crosses a midpoint constantly. Going
    /// light needs a clearly light backdrop and going dark needs a clearly dark one; in the band
    /// between, whatever was decided last stands.
    private static let lightEnough = 0.62
    private static let darkEnough = 0.45

    /// The grab is downsampled to this before averaging. Sixteen squares of a panel-sized region
    /// is plenty to answer "is this broadly light or broadly dark", and it is the whole reason the
    /// sampler is affordable at all.
    private static let sampleSide = 16

    // MARK: - Lifecycle

    func start(for window: NSWindow) {
        guard !isUnavailable else { return }
        self.window = window
        guard observers.isEmpty else { return }

        // Ask outright rather than relying on the first capture to ask for us.
        //
        // Leaving it implicit made "has it even started?" unanswerable: the first build shipped
        // with no prompt seen and no capture attempt recorded in the log, and nothing in the code
        // could distinguish "permission was never requested" from "the panel was never opened".
        // These two calls remove the ambiguity — preflight reports the current grant with no side
        // effects, and request is what actually puts the dialog on screen — and the log lines
        // either side mean the answer is in `log show` rather than inferred.
        //
        // A refusal is final for the life of the process — macOS shows this dialog once, and
        // after that the only way in is System Settings › Privacy & Security › Screen Recording,
        // which also needs the app relaunched. So a denial latches and the panel keeps the
        // system appearance, exactly as it behaved before the sampler existed.
        let alreadyGranted = CGPreflightScreenCaptureAccess()
        NSLog("[MiniPlayerBackdrop] start — screen recording granted: \(alreadyGranted)")
        if !alreadyGranted {
            guard CGRequestScreenCaptureAccess() else {
                isUnavailable = true
                NSLog("[MiniPlayerBackdrop] screen recording refused — keeping the system appearance")
                return
            }
        }

        observe(NSWindow.didMoveNotification, from: window)
        observe(NSWindow.didResizeNotification, from: window)
        // The one that saves the most: when the panel is hidden behind something, on another
        // Space, or minimised, this fires and `shouldSample` goes false until it comes back.
        observe(NSWindow.didChangeOcclusionStateNotification, from: window)
        observe(NSApplication.didChangeScreenParametersNotification, from: nil)

        // Switching app is the single most likely way for the backdrop to change completely, and
        // it is announced — so it is worth listening for rather than waiting out a heartbeat.
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(
            workspace.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.sampleSoon() }
            }
        )

        startHeartbeat()
        sampleSoon()
    }

    func stop() {
        heartbeat?.cancel()
        heartbeat = nil
        debounce?.cancel()
        debounce = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        observers.removeAll()
    }

    deinit {
        heartbeat?.cancel()
        debounce?.cancel()
    }

    private func observe(_ name: Notification.Name, from object: AnyObject?) {
        observers.append(
            NotificationCenter.default.addObserver(
                forName: name,
                object: object,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.sampleSoon() }
            }
        )
    }

    private func startHeartbeat() {
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.heartbeatInterval)
                guard !Task.isCancelled, let self else { return }
                if self.isUnavailable { return }
                await self.sampleOnce()
            }
        }
    }

    /// Coalesces a burst of triggers into one capture, once the burst has stopped.
    private func sampleSoon() {
        guard !isUnavailable else { return }
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: Self.settle)
            guard !Task.isCancelled else { return }
            await self?.sampleOnce()
        }
    }

    /// Whether a capture would tell us anything. A panel nobody can see does not need an
    /// appearance, and this is what keeps the sampler at zero cost most of the time.
    private var shouldSample: Bool {
        guard !isUnavailable, let window else { return false }
        return window.isVisible && window.occlusionState.contains(.visible)
    }

    // MARK: - Measuring

    private func sampleOnce() async {
        guard shouldSample, let window else { return }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            guard let display = display(for: window, in: content) else { return }

            // Excluding our own window is not a refinement, it is the whole thing working: the
            // panel is transparent glass, so a capture that included it would be measuring the
            // panel's rendering of the backdrop rather than the backdrop, and each reading would
            // drag the next one toward whatever it just decided.
            let ours = content.windows.filter { $0.windowID == CGWindowID(window.windowNumber) }
            let filter = SCContentFilter(display: display, excludingWindows: ours)

            guard let region = sourceRect(for: window, on: display) else { return }

            let configuration = SCStreamConfiguration()
            configuration.sourceRect = region
            configuration.width = Self.sampleSide
            configuration.height = Self.sampleSide
            configuration.showsCursor = false
            configuration.captureResolution = .nominal

            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
            guard let luminance = Self.averageLuminance(of: image) else { return }
            apply(luminance: luminance)
        } catch {
            // Almost always "the user said no", which is a settled answer rather than a failure to
            // retry against. Anything else here is a display that went away mid-read, and giving
            // up on it costs a panel that keeps the system appearance.
            isUnavailable = true
            NSLog("[MiniPlayerBackdrop] backdrop sampling unavailable: \(error.localizedDescription)")
            stop()
        }
    }

    private func apply(luminance: Double) {
        let wantsLight: Bool
        switch luminance {
        case Self.lightEnough...: wantsLight = true
        case ..<Self.darkEnough: wantsLight = false
        default: return                       // inside the band: leave the last decision standing
        }

        guard wantsLight != isLight else { return }
        isLight = wantsLight
        window?.appearance = NSAppearance(named: wantsLight ? .aqua : .darkAqua)
        NSLog("[MiniPlayerBackdrop] luminance \(String(format: "%.2f", luminance)) — \(wantsLight ? "light" : "dark")")
    }

    // MARK: - Geometry

    private func display(for window: NSWindow, in content: SCShareableContent) -> SCDisplay? {
        guard let screen = window.screen ?? NSScreen.main,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return content.displays.first }
        let id = CGDirectDisplayID(number.uint32Value)
        return content.displays.first { $0.displayID == id } ?? content.displays.first
    }

    /// The panel's frame, in the capture's coordinate space.
    ///
    /// Two conversions, and both are easy to get silently wrong. AppKit measures from the bottom
    /// left of the *primary* screen and Core Graphics from the top left of it, so the y axis has to
    /// be flipped against the primary screen's height — not against the screen the window happens
    /// to be on. Then `sourceRect` is relative to the display being captured, so the display's own
    /// origin comes off both axes.
    private func sourceRect(for window: NSWindow, on display: SCDisplay) -> CGRect? {
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return nil }
        let frame = window.frame
        let flipped = CGRect(
            x: frame.minX,
            y: primaryHeight - frame.maxY,
            width: frame.width,
            height: frame.height
        )
        let bounds = CGDisplayBounds(display.displayID)
        let local = CGRect(
            x: flipped.minX - bounds.minX,
            y: flipped.minY - bounds.minY,
            width: flipped.width,
            height: flipped.height
        )
        // A panel dragged half off the edge would otherwise ask for pixels the display does not
        // have, which fails the capture outright rather than returning the part that exists.
        let clamped = local.intersection(CGRect(origin: .zero, size: bounds.size))
        return clamped.isNull || clamped.width < 1 || clamped.height < 1 ? nil : clamped
    }

    // MARK: - Pixels

    /// Mean relative luminance of the grab, 0...1.
    ///
    /// Rec. 709 weights rather than a flat mean of the channels: the eye is far more sensitive to
    /// green than to blue, and a flat average calls a saturated blue backdrop "mid" and leaves
    /// black text on it. Redrawn into a known sRGB buffer instead of reading the image's own
    /// bytes, because the capture's layout is not guaranteed and guessing it produces a luminance
    /// that is wrong in a way nothing downstream can detect.
    private static func averageLuminance(of image: CGImage) -> Double? {
        let side = sampleSide
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: &pixels,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: side * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }

        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))

        var total = 0.0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[index]) / 255
            let g = Double(pixels[index + 1]) / 255
            let b = Double(pixels[index + 2]) / 255
            total += 0.2126 * r + 0.7152 * g + 0.0722 * b
        }
        return total / Double(side * side)
    }
}
