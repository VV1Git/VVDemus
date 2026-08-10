import XCTest

/// Walks the app and photographs every screen.
///
/// Not an assertion suite — it is a camera. The things it looks for (a control pushed off the
/// edge, a label truncated to nothing, a colour that vanishes in dark mode, an empty state that
/// renders as a blank pane) are exactly the defects that pass every unit test, because nothing
/// about them throws. A picture of each screen is the only artefact that catches them, and it
/// makes a UI regression reviewable by someone who is not holding the phone.
///
/// `continueAfterFailure` is on, deliberately. A tour that stops at the first screen it cannot
/// reach returns three pictures and no information about the other ten — which is what happened
/// the first time this ran, when the keyboard left over from the search step covered the tab bar.
/// Every step is soft: it records what it could not reach and carries on, so one bad step costs
/// one screenshot rather than the whole run.
final class ScreenTour: XCTestCase {
    private var app: XCUIApplication!
    private var missed: [String] = []

    override func setUpWithError() throws {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchEnvironment["VVDEMUS_UITEST"] = "1"
        app.launch()
    }

    override func tearDownWithError() throws {
        if !missed.isEmpty {
            XCTFail("screens the tour could not reach: \(missed.joined(separator: ", "))")
        }
    }

    // MARK: - Camera

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Waits for something that proves the screen arrived, then photographs it.
    ///
    /// Records rather than throws — see the note on `continueAfterFailure`. The screenshot is
    /// taken either way: a picture of the wrong screen is itself the evidence of what went wrong.
    @discardableResult
    private func arrive(_ name: String, at element: XCUIElement, timeout: TimeInterval = 12) -> Bool {
        let appeared = element.waitForExistence(timeout: timeout)
        if !appeared { missed.append(name) }
        // A beat for the glass and the artwork gradient to settle, or the shot catches a
        // half-drawn transition and every reviewer reports the same phantom defect.
        Thread.sleep(forTimeInterval: 0.7)
        shot(name)
        return appeared
    }

    // MARK: - Getting about

    /// Taps a tab, expanding the bar first if it has shrunk.
    ///
    /// While something is playing the system collapses the tab bar to a pill to make room for the
    /// mini player accessory, and the other tabs stop being hittable — they are still in the tree,
    /// reported as `value: Collapsed`. A tour that taps them directly fails with "No matches found
    /// for Elements matching predicate", which is exactly what happened the first time this ran
    /// against a phone that was mirroring the other device's playback.
    private func tapTab(_ name: String) {
        let bar = app.tabBars.firstMatch
        var button = bar.buttons[name].exists ? bar.buttons[name] : app.buttons[name]
        if !button.isHittable, bar.exists {
            // Tapping the selected tab expands the pill back to a full bar.
            bar.buttons.element(boundBy: 0).tap()
            Thread.sleep(forTimeInterval: 0.6)
            button = bar.buttons[name].exists ? bar.buttons[name] : app.buttons[name]
        }
        guard button.exists, button.isHittable else {
            missed.append("tab '\(name)' was not reachable")
            return
        }
        button.tap()
    }

    private func tab(_ name: String) -> XCUIElement {
        app.tabBars.buttons[name].exists ? app.tabBars.buttons[name] : app.buttons[name]
    }

    /// The tab bar lives under the keyboard, so anything that typed has to put it away first.
    private func dismissKeyboard() {
        guard app.keyboards.count > 0 else { return }
        if app.keyboards.buttons["search"].exists {
            app.keyboards.buttons["search"].tap()
        } else if app.keyboards.buttons["Search"].exists {
            app.keyboards.buttons["Search"].tap()
        } else {
            app.swipeDown()
        }
        _ = app.keyboards.firstMatch.waitForNonExistence(timeout: 3)
    }

    private func goBack() {
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if back.exists, back.isHittable { back.tap() }
    }

    /// Opens a Library row by name, photographs it, and comes back. Missing rows are recorded
    /// rather than fatal — a fresh install legitimately has no playlists.
    private func visitLibraryRow(_ label: String, _ name: String) {
        let row = app.staticTexts[label].firstMatch
        guard row.waitForExistence(timeout: 5), row.isHittable else {
            missed.append("\(name) (no '\(label)' row)")
            return
        }
        row.tap()
        arrive(name, at: app.navigationBars.firstMatch)
        goBack()
    }

    // MARK: - The tour

    func testTourEveryScreen() throws {
        arrive("01-home", at: app.scrollViews.firstMatch)

        // Home, scrolled — the shelves below the fold never appear in a first-screen shot.
        app.swipeUp()
        Thread.sleep(forTimeInterval: 0.5)
        shot("02-home-scrolled")

        // MARK: Search
        tapTab("Search")
        arrive("03-search-empty", at: app.searchFields.firstMatch)

        let field = app.searchFields.firstMatch
        if field.exists {
            field.tap()
            field.typeText("daft punk")
            _ = app.cells.firstMatch.waitForExistence(timeout: 20)
            Thread.sleep(forTimeInterval: 1.0)
            shot("04-search-results")
            dismissKeyboard()
            shot("05-search-results-no-keyboard")
        }

        // MARK: Library and its leaves
        tapTab("Library")
        arrive("06-library", at: app.staticTexts["Liked Songs"].firstMatch)
        visitLibraryRow("Liked Songs", "07-liked-songs")
        visitLibraryRow("Downloads", "08-downloads")
        visitLibraryRow("Your Stats", "09-stats")

        // MARK: Settings, and the pairing screen the device picker depends on
        let settings = app.staticTexts["Settings"].firstMatch
        if settings.waitForExistence(timeout: 5), settings.isHittable {
            settings.tap()
            arrive("10-settings", at: app.navigationBars.firstMatch)
            let paired = app.staticTexts["Paired Device"].firstMatch
            if paired.waitForExistence(timeout: 4), paired.isHittable {
                paired.tap()
                arrive("11-pairing", at: app.navigationBars.firstMatch)
                goBack()
            } else {
                missed.append("11-pairing")
            }
            goBack()
        } else {
            missed.append("10-settings")
        }

        // MARK: Playback — the mini player, Now Playing, the device picker, the queue
        tapTab("Search")
        let firstResult = app.cells.firstMatch
        guard firstResult.waitForExistence(timeout: 10), firstResult.isHittable else {
            missed.append("12-mini-player (no search result to play)")
            return
        }
        firstResult.tap()
        Thread.sleep(forTimeInterval: 4)
        shot("12-mini-player")

        // The mini bar is the only route into Now Playing.
        let mini = app.buttons["Now Playing"].exists
            ? app.buttons["Now Playing"]
            : app.otherElements["MiniPlayerBar"].firstMatch
        if mini.exists, mini.isHittable {
            mini.tap()
        } else {
            // The accessory sits just above the tab bar; tap it by coordinate rather than by
            // identity, so a missing accessibility id costs a label and not the screenshot.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.88)).tap()
        }
        Thread.sleep(forTimeInterval: 2.5)
        shot("13-now-playing")

        // The device picker: the one control that moves playback between devices.
        let picker = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Playing on'")).firstMatch
        if picker.exists, picker.isHittable {
            picker.tap()
            Thread.sleep(forTimeInterval: 1.0)
            shot("14-device-picker")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
        } else {
            // Correct when nothing is paired — the picker deliberately hides itself. Recorded so
            // the reviewer knows the shot is absent by design rather than missing.
            missed.append("14-device-picker (no paired device — expected on a fresh install)")
        }

        let queue = app.buttons["Queue"].firstMatch
        if queue.waitForExistence(timeout: 5), queue.isHittable {
            queue.tap()
            arrive("15-queue", at: app.navigationBars.firstMatch)
        } else {
            missed.append("15-queue")
        }
    }
}
