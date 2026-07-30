import SwiftUI

/// The app's glass material: a blurred, translucent slab with a lit rim and its own
/// elevation, so a panel reads as floating above the content behind it rather than as an
/// opaque card sitting in the same plane.
///
/// Hand-built rather than SwiftUI's `.glassEffect(_:in:)`. That modifier — and
/// `GlassEffectContainer` with it — arrived in iOS 26 and ships in the Xcode 26 SDK, while
/// this project builds against iOS 18.5 with a deployment target of iOS 17: the symbols do
/// not exist to call, so there is nothing to `#available`-gate against. What follows is the
/// same recipe assembled from parts that do exist — a material blur standing in for the
/// refraction, a tint borrowed from the artwork, a specular rim for the lit edge, and a
/// shadow for the lift.
///
/// Every one of those decisions lives here and nowhere else, which is the point: when the
/// toolchain moves to Xcode 26, adopting the real modifier is a change to this one file
/// instead of a hunt through every view that happens to look like glass.
struct GlassSurface<S: InsettableShape>: View {
    var shape: S
    /// Colour borrowed from the current artwork, so the glass picks up what is behind it the
    /// way real glass would. Nil for chrome with no artwork to sample — the material's own
    /// grey is the right answer there.
    var tint: Color?
    var elevation: GlassElevation = .raised

    var body: some View {
        shape
            .fill(.ultraThinMaterial)
            .overlay(lift)
            .overlay(tintLayer)
            .overlay(sheen)
            .overlay(rim)
            // Groups the stack before the shadow is applied, so one shadow is cast by the
            // composed slab. Without it each layer casts its own and the edges muddy.
            .compositingGroup()
            .shadow(color: elevation.shadowColor, radius: elevation.shadowRadius, y: elevation.shadowOffset)
    }

    /// A flat lift off the background.
    ///
    /// The app forces dark mode over a black background, where `.ultraThinMaterial` has
    /// almost nothing to blur and resolves to near-black — glass that is invisible against
    /// the page it's supposed to be floating over. This is what keeps the slab reading as a
    /// lighter pane of glass rather than a hole.
    private var lift: some View {
        shape.fill(Color.white.opacity(0.06))
    }

    @ViewBuilder private var tintLayer: some View {
        if let tint {
            shape.fill(
                LinearGradient(
                    colors: [tint.opacity(0.34), tint.opacity(0.10)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
    }

    /// Light catching the upper curve of the slab. Falls off well before the bottom edge —
    /// a uniform wash reads as translucent plastic, not glass.
    private var sheen: some View {
        shape.fill(
            LinearGradient(
                stops: [
                    .init(color: .white.opacity(0.20), location: 0),
                    .init(color: .white.opacity(0.06), location: 0.35),
                    .init(color: .clear, location: 0.75),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    /// The bright edge. This is what actually separates the slab from a black background,
    /// where a shadow contributes nothing at all — so it stays even at `.flush`.
    private var rim: some View {
        shape
            .strokeBorder(
                LinearGradient(
                    stops: [
                        .init(color: .white.opacity(0.75), location: 0),
                        .init(color: .white.opacity(0.16), location: 0.45),
                        .init(color: .white.opacity(0.40), location: 1),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1
            )
            .blendMode(.plusLighter)
    }
}

/// How far off the page a glass surface sits.
enum GlassElevation {
    /// Inline surfaces — chips, section headers, anything belonging to the page it's on.
    case flush
    /// Cards and sheets: a layer above the page.
    case raised
    /// Detached from every edge, like the bottom bar. Needs a shadow dark enough to hold it
    /// apart from artwork that may be any colour at all.
    case floating

    var shadowColor: Color {
        switch self {
        case .flush: return .clear
        case .raised: return .black.opacity(0.30)
        case .floating: return .black.opacity(0.50)
        }
    }

    var shadowRadius: CGFloat {
        switch self {
        case .flush: return 0
        case .raised: return 10
        case .floating: return 20
        }
    }

    var shadowOffset: CGFloat {
        switch self {
        case .flush: return 0
        case .raised: return 4
        case .floating: return 10
        }
    }
}

extension View {
    /// Puts a glass slab behind this view.
    ///
    /// Deliberately does **not** clip the content. The shadow belongs to the background
    /// layer, and a `clipShape` applied to the composite would cut it off — leaving a
    /// floating bar with no lift at all. Views whose own content needs clipping to the same
    /// outline (artwork, a progress hairline running to the edge) call `.clipShape` on that
    /// content *before* this, which clips the content and leaves the backing slab whole.
    func glassSurface<S: InsettableShape>(
        in shape: S,
        tint: Color? = nil,
        elevation: GlassElevation = .raised
    ) -> some View {
        background(GlassSurface(shape: shape, tint: tint, elevation: elevation))
    }

    /// The common case: continuous corners, which read as glass where a circular corner
    /// radius reads as a rounded rectangle.
    ///
    /// A note on where to use this: the material blur is composited per surface, so putting
    /// it behind rows of a scrolling list costs real frames. Glass belongs on chrome — bars,
    /// panels, headers, a handful of cards — and plain fills belong on list rows.
    func glassSurface(
        cornerRadius: CGFloat,
        tint: Color? = nil,
        elevation: GlassElevation = .raised
    ) -> some View {
        glassSurface(
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
            tint: tint,
            elevation: elevation
        )
    }
}

/// A round glass button for a bare icon — the Now Playing chrome, where a filled circle
/// would be too loud but a naked glyph on artwork has nothing to hold it.
struct GlassCircleButtonStyle: ButtonStyle {
    var diameter: CGFloat = 40

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: diameter, height: diameter)
            .glassSurface(in: Circle(), elevation: .flush)
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.65), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == GlassCircleButtonStyle {
    static var glassCircle: GlassCircleButtonStyle { GlassCircleButtonStyle() }
}
