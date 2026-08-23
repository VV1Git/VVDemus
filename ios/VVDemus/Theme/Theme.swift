import SwiftUI
#if os(iOS)
// Only for `Haptics` at the bottom of this file — everything above is SwiftUI.
import UIKit
#endif

enum Theme {
    // MARK: - Palette

    static let background = Color.black
    /// The ground a whole screen paints behind itself. `background` is still the right answer
    /// for a surface *inside* a screen; this is only for the screen itself.
    ///
    /// The two platforms want different things here, and asking for black on both is what made
    /// the Mac inconsistent with itself. The phone is black everywhere by design — it declares
    /// `UIUserInterfaceStyle: Dark`, the palette above is tuned against black, and Now Playing
    /// runs an artwork gradient down into it.
    ///
    /// The Mac has none of that and never asked for it. What it had instead was a split: screens
    /// built on `List` were already showing the window's own material, because a `List` paints
    /// its background *over* anything behind it, so `.background(Theme.background)` on those
    /// screens did nothing at all. Only the `ScrollView` screens — Home the obvious one — came
    /// out black. Every screen was asking for the same thing and roughly half were quietly
    /// losing, which read as a design decision rather than the accident it was.
    ///
    /// So on macOS this is nothing, and the window supplies the ground for every screen alike.
    /// `SettingsView` reaches for `.scrollContentBackground(.hidden)` to win that argument on
    /// one screen, and still needs to on the phone, where black is the point. It is the only
    /// screen that ever did — which is the tell that the Mac's split was an accident.
    static var screenBackground: Color {
        #if os(macOS)
        .clear
        #else
        background
        #endif
    }
    /// Opaque surfaces and image placeholders ONLY — never a separator or a border.
    static let card = Color(white: 0.12)
    /// Pressed / raised surface ONLY.
    static let cardLight = Color(white: 0.18)
    static let accent = Color(red: 0.11, green: 0.73, blue: 0.33)
    /// Failed downloads and a rate-limited batch: both are "this needs you", neither is
    /// destructive, and the accent green is already the "this worked" colour.
    static let warning = Color(red: 0.95, green: 0.62, blue: 0.23)
    /// Hand-drawn `Divider`s only. Never `.listRowSeparatorTint` — the system separator
    /// is already correct in dark mode, and tinting it only makes it worse.
    static let separator = Color(white: 0.24)

    // MARK: - Spacing

    /// 4pt scale. No other numeric spacing/padding is permitted.
    enum Space {
        static let xs: CGFloat = 4      // intra-label (title↔subtitle uses Metrics.labelSpacing)
        static let sm: CGFloat = 8
        static let md: CGFloat = 12     // canonical: artwork ↔ text, control ↔ control group
        static let lg: CGFloat = 16     // canonical screen gutter
        static let xl: CGFloat = 24     // between major blocks
        static let xxl: CGFloat = 32
    }

    // MARK: - Radii

    /// Always `.continuous` — build shapes with `Theme.Radius.rect(_:)` so nothing drifts.
    enum Radius {
        static let artSmall: CGFloat = 6      // artwork ≤ 64pt
        static let artMedium: CGFloat = 10    // artwork 65…199pt (shelf cards)
        static let artHero: CGFloat = 14      // artwork ≥ 200pt
        static let card: CGFloat = 16         // filled/glass containers, tiles, summary cards
        static let panel: CGFloat = 26        // Now Playing control slab

        static func art(for size: CGFloat) -> CGFloat {
            size <= 64 ? artSmall : (size < 200 ? artMedium : artHero)
        }

        static func rect(_ r: CGFloat) -> RoundedRectangle {
            RoundedRectangle(cornerRadius: r, style: .continuous)
        }
    }

    // MARK: - Artwork sizes

    /// These seven values are the complete set.
    enum ArtSize {
        static let mini: CGFloat = 44         // compact bars: the Mac transport bar, the resume bar
        /// The iOS tab-bar accessory, whose interior is 46pt. At `mini` the expanded mini player
        /// asked for 6 + 44 + 6 + a 2pt progress hairline = 58pt inside it, so the artwork was
        /// pressed against the top rim of the glass pill with ~1pt of clearance and the hairline
        /// was pushed outside the capsule entirely. 4 + 36 + 4 + 2 is exactly 46.
        static let accessory: CGFloat = 36
        static let row: CGFloat = 48          // EVERY list row, EVERY screen
        static let tile: CGFloat = 56         // Home 2-column shortcut grid tile only
        static let daylist: CGFloat = 64      // DaylistCard
        static let shelfCard: CGFloat = 150   // all horizontal shelf cards
        static let heroMax: CGFloat = 280     // detail hero + Now Playing, container-capped
    }

    // MARK: - Layout metrics

    enum Metrics {
        static let gutter: CGFloat = Space.lg           // one content inset app-wide
        static let rowVertical: CGFloat = 6             // 48 + 6 + 6 = 60pt row
        static let hitTarget: CGFloat = 44
        /// VISUAL width of a trailing row control; its height stays `hitTarget`.
        static let trailingControl: CGFloat = 32
        static let labelSpacing: CGFloat = 2            // title ↔ subtitle, everywhere
        /// Separator starts at the leading edge of the title text (iOS convention).
        /// Measured in the row's own coordinate space, i.e. after `rowInsets`.
        static let separatorLeading: CGFloat = ArtSize.row + Space.md   // 60

        static let rowInsets = EdgeInsets(top: rowVertical, leading: gutter,
                                          bottom: rowVertical, trailing: gutter)
    }
}

// MARK: - Typography roles

/// One role, one font, all screens. Nothing outside this extension may compose a font.
extension Font {
    static let rowTitle = Font.body                             // 17 regular
    static let rowSubtitle = Font.subheadline                   // 15
    static let shelfHeader = Font.title3.weight(.semibold)      // ScrollView shelves only
    /// The verdict line at the top of a sheet's result screen — currently the Spotify
    /// import's "Imported …" / "Nothing was imported". Deliberately a separate role from
    /// `shelfHeader` despite resolving to the same font: that one is documented as belonging
    /// to shelves, so borrowing it here would mean a later change to shelf typography
    /// silently restyled a modal that has nothing to do with shelves.
    static let sheetHeadline = Font.title3.weight(.semibold)
    /// Every card title on Home — the daylist card, the 2-column grid tiles and the shelf
    /// cards. They stack vertically on one screen, so they get one size between them.
    static let cardTitle = Font.subheadline.weight(.semibold)   // 15 semibold
    static let cardSubtitle = Font.caption
    static let heroTitle = Font.title.weight(.bold)             // collection hero
    static let nowPlayingTitle = Font.title2.weight(.bold)      // the track, over its artwork
    static let statValue = Font.title2.weight(.bold)            // a number on a summary card
    static let miniTitle = Font.subheadline.weight(.medium)
    static let miniSubtitle = Font.caption
    static let meta = Font.caption                              // stats, counters, timestamps
    static let controlLabel = Font.footnote.weight(.semibold)   // small text buttons
    /// A glyph in a row's trailing controls — the like heart, and anything that sits beside the
    /// download ring. Sized to match that ring's 20pt frame: unset, the heart rendered about 30%
    /// smaller than the ring next to it, so the download read as the heavier control on every
    /// row in the app.
    static let trailingGlyph = Font.title3
    /// The six digits on the pairing screen. Built on a text style rather than the fixed
    /// `.system(size: 44)` it replaced, which was the one number on that screen that did not
    /// grow with Dynamic Type — exactly backwards for a code someone has to read off one
    /// device and type into another. Monospaced so the digits sit on a fixed grid and the
    /// string doesn't shuffle sideways when the code rolls over every 30 seconds.
    static let pairingCode = Font.largeTitle.weight(.semibold).monospaced()
}

// MARK: - Button styles

/// Gives a button a small amount of "give" when pressed.
///
/// Almost every control in the app uses `.buttonStyle(.plain)` to avoid SwiftUI tinting
/// its label blue — but that also throws away the default press highlight, leaving taps
/// with no acknowledgement at all. This restores a deliberate one: a slight shrink and
/// dim, springing back on release.
struct PressableButtonStyle: ButtonStyle {
    /// Large controls need proportionally less shrink to read as the same gesture.
    var scale: CGFloat = 0.92
    var pressedOpacity: Double = 0.65

    func makeBody(configuration: Configuration) -> some View {
        Effects(configuration: configuration, scale: scale, pressedOpacity: pressedOpacity)
    }

    /// A `ButtonStyle` value is not itself part of the view hierarchy, so `@Environment`
    /// declared on it never resolves. Reduce Motion and `isEnabled` have to be read from
    /// a real nested `View`.
    private struct Effects: View {
        let configuration: ButtonStyleConfiguration
        let scale: CGFloat
        let pressedOpacity: Double

        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .scaleEffect(configuration.isPressed && !reduceMotion ? scale : 1)
                .opacity(configuration.isPressed ? pressedOpacity : 1)
                // A disabled control that draws at full strength still looks tappable.
                .opacity(isEnabled ? 1 : 0.4)
                .animation(.spring(response: 0.25, dampingFraction: 0.65), value: configuration.isPressed)
        }
    }
}

/// Press feedback for full-width rows: dim only. Scaling a row that spans the screen
/// reads as a rendering glitch rather than a press.
struct RowButtonStyle: ButtonStyle {
    var pressedOpacity: Double = 0.6

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? pressedOpacity : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressableButtonStyle {
    /// Default press feedback, for icon-sized controls.
    static var pressable: PressableButtonStyle { PressableButtonStyle() }

    /// For big targets — artwork cards, the main play button — where a 0.92 shrink is too
    /// much movement.
    static var pressableCard: PressableButtonStyle {
        PressableButtonStyle(scale: 0.97, pressedOpacity: 0.85)
    }
}

extension ButtonStyle where Self == RowButtonStyle {
    /// For list rows and other full-width tappable regions.
    static var pressableRow: RowButtonStyle { RowButtonStyle() }
}

// MARK: - Haptics

/// Haptics for actions triggered by a swipe rather than a tap: with no button to watch
/// depress, a small tap through the case is the only confirmation the gesture registered.
/// A Mac has no Taptic Engine, so this does nothing there. The style parameter went with the
/// port rather than being given a platform-independent type of its own: every one of the call
/// sites took the `.light` default, so it was an unused generalization whose only concrete
/// type was `UIImpactFeedbackGenerator.FeedbackStyle`.
enum Haptics {
    #if os(iOS)
    /// The generator is cached and re-`prepare()`d after every use. An unprepared generator
    /// has to spin the Taptic Engine up first, so the very first swipe's tap used to land
    /// after its animation had already resolved.
    private static var generator: UIImpactFeedbackGenerator?

    static func impact() {
        let generator = generator ?? {
            let made = UIImpactFeedbackGenerator(style: .light)
            made.prepare()
            Self.generator = made
            return made
        }()
        generator.impactOccurred()
        generator.prepare()
    }
    #else
    static func impact() {}
    #endif
}
