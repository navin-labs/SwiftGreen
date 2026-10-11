import SwiftUI

// MARK: - SwiftGreen Design System
//
// The single source of truth for colour, type, spacing, radius and motion.
// Greyscale, except the status colours below, which appear only where colour
// carries meaning.
//
// One appearance, always dark: a matte charcoal backdrop lit softly from above by a
// faint, fixed white and silver glow (`SGBackdrop`). Cards, panels and pills on top
// are soft raised slabs (`sgGlass`): a light top edge and a deep shadow. Reduce
// Transparency swaps them for solid dark surfaces; Increase Contrast brightens the edges.

enum SG {

    // MARK: Spacing — 4pt grid
    enum Space {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
    }

    // MARK: Radius
    enum Radius {
        /// Every card, row and field in the app. Pills use `Capsule()` instead.
        static let card: CGFloat = 18
        /// Small inline tiles (app icons, thumbnails) where 20 would look like a circle.
        static let tile: CGFloat = 10
    }

    // MARK: Typography
    enum Font {
        static let screenTitle = SwiftUI.Font.system(size: 28, weight: .bold)
        static let section = SwiftUI.Font.system(size: 20, weight: .semibold)
        static let rowTitle = SwiftUI.Font.system(size: 14, weight: .semibold)
        static let body = SwiftUI.Font.system(size: 13)
        static let caption = SwiftUI.Font.system(size: 11)
        static let empty = SwiftUI.Font.system(size: 15)
        /// Tabular figures for readouts that update in place — battery, latency,
        /// byte counts. Proportional digits jitter the layout on every tick.
        static func mono(_ size: CGFloat, weight: SwiftUI.Font.Weight = .regular) -> SwiftUI.Font {
            .system(size: size, weight: weight, design: .monospaced)
        }
    }

    // MARK: Motion
    enum Motion {
        /// Hover, press, chip toggles.
        static let quick = Animation.easeOut(duration: 0.15)
        /// State changes, list inserts, progress.
        static let standard = Animation.easeOut(duration: 0.25)
        /// Connection state transitions, which read as physical.
        static let spring = Animation.spring(response: 0.4, dampingFraction: 0.8)
    }
}

// MARK: - Image Decoding

extension NSImage {
    /// Base64 → image, tolerating nil and empty input.
    ///
    /// Android sends every image over the wire this way — notification icons, sender
    /// photos, album art, file thumbnails. This is the third call site, which is one
    /// past where the same four lines stop being worth re-typing.
    convenience init?(base64: String?) {
        guard let base64, !base64.isEmpty,
              let data = Data(base64Encoded: base64) else { return nil }
        self.init(data: data)
    }
}

// MARK: - Navigation Bus

extension Notification.Name {
    /// Posted with a `Tab` as the object. Lets deep views (empty-state CTAs,
    /// suggestions) request navigation without threading a binding through every
    /// intermediate view.
    static let sgNavigate = Notification.Name("SwiftGreenNavigate")
}

// MARK: - Colour Tokens
//
// ponytail: `emerald` keeps its historical name because six files reference it
// and renaming them all buys nothing visually. Its value is white. Every other
// token is namespaced `sg*`.
extension Color {
    static let emerald = Color.white

    /// Near-black ink: labels and glyphs on white controls, and popover bases.
    /// Panes don't paint it any more; they use `sgCanvas`.
    static let sgBackground   = Color(red:  8/255, green:  8/255, blue:  8/255)
    /// A pane's own fill: clear, so the window's `SGBackdrop` shows through.
    static let sgCanvas       = Color.clear
    /// Solid charcoal: the backdrop when Reduce Transparency is on.
    static let sgCharcoal     = Color(red: 28/255, green: 28/255, blue: 30/255)
    /// Solid raised charcoal: cards and pills when Reduce Transparency is on.
    static let sgCharcoalRaised = Color(red: 44/255, green: 44/255, blue: 48/255)
    /// Soft white and a cool silver: the ambient light only, never UI state. Monochrome,
    /// like light falling on objects in a dark studio; colour is kept for status.
    static let sgGlowWhite    = Color.white
    static let sgGlowSilver   = Color(red: 200/255, green: 210/255, blue: 225/255)
    /// Translucent white for hover highlights, wells and fields *inside* glass.
    /// Cards, panels and pills are glass (`sgGlass`), never these fills.
    static let sgSurface      = Color.white.opacity(0.07)
    static let sgSurfaceHigh  = Color.white.opacity(0.12)
    static let sgTextSecondary = Color.white.opacity(0.6)
    /// Hairline separators only. Never a card border.
    static let sgHairline     = Color.white.opacity(0.08)

    // Status colours: the system's own, so they track light/dark and Increase Contrast.
    // Only where colour carries meaning: call/answer vs decline/hang up, the connection
    // dot, battery state, destructive confirmations, and sent/failed markers. Nothing
    // else in the app should reach for these.
    /// systemGreen: #34C759 light / #30D158 dark.
    static let sgSuccess = Color(nsColor: .systemGreen)
    /// systemRed: #FF3B30 light / #FF453A dark.
    static let sgDanger  = Color(nsColor: .systemRed)
    /// systemOrange (#FF9F0A dark).
    static let sgWarning = Color(nsColor: .systemOrange)
    /// systemYellow (#FFD60A dark), for battery in Low Power Mode.
    static let sgWarningBattery = Color(nsColor: .systemYellow)

    /// The battery readout's colour: green while charging, red at 20% or less, the
    /// normal text colour otherwise. The phone doesn't report Low Power Mode, so the
    /// yellow case never occurs today.
    static func sgBattery(_ level: Int, charging: Bool) -> Color? {
        if charging { return .sgSuccess }
        if level <= 20 { return .sgDanger }
        return nil
    }
}

// MARK: - Window, Backdrop and Glass

/// Makes the hosting window genuinely translucent: not opaque, clear background,
/// content under a transparent titlebar. Without this the behind-window material has
/// nothing to blur and the whole app reads as flat grey.
struct SGTranslucentWindow: NSViewRepresentable {
    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
        }
    }
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) {}
}

/// The app's backdrop, behind every pane: a matte charcoal gradient and the ambient
/// glow. Solid charcoal with Reduce Transparency.
struct SGBackdrop: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        if reduceTransparency {
            Color.sgCharcoal
        } else {
            // Matte charcoal, lit softly from above: a dark studio, not a window onto
            // the wallpaper.
            ZStack {
                LinearGradient(colors: [Color(white: 0.145), Color(white: 0.105)],
                               startPoint: .top, endPoint: .bottom)
                SGAmbientGlow()
            }
        }
    }
}

/// Two very soft, very large radial lights, white and cool silver, at 9% or less. Fixed in place, never animated: they tint the glass above so it
/// reads as lit, not grey.
struct SGAmbientGlow: View {
    var body: some View {
        GeometryReader { geo in
            let r = max(geo.size.width, geo.size.height)
            ZStack {
                // A soft key light from above, and a faint cool rim bottom-right.
                RadialGradient(colors: [Color.sgGlowWhite.opacity(0.06), .clear],
                               center: UnitPoint(x: 0.35, y: -0.1), startRadius: 0, endRadius: r * 0.7)
                RadialGradient(colors: [Color.sgGlowSilver.opacity(0.03), .clear],
                               center: UnitPoint(x: 1.0, y: 1.0), startRadius: 0, endRadius: r * 0.6)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A raised slab in `shape`, or, with Reduce Transparency, a solid dark fill with a
/// hairline edge (thicker with Increase Contrast). `highlighted` lifts a selected
/// element with a faint white tint.
struct SGGlassSurface<S: Shape>: ViewModifier {
    let shape: S
    var highlighted = false
    var interactive = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(shape.fill(highlighted ? Color(red: 64/255, green: 64/255, blue: 70/255) : Color.sgCharcoalRaised))
                .overlay(shape.stroke(Color.white.opacity(contrast == .increased ? 0.4 : 0.12), lineWidth: 1))
        } else {
            // A soft raised slab: faintly lighter at the top, a light edge that fades
            // downward, and a deep diffuse shadow underneath.
            content
                .background(shape.fill(LinearGradient(
                    colors: highlighted ? [Color(white: 0.23), Color(white: 0.19)]
                                        : [Color(white: 0.175), Color(white: 0.145)],
                    startPoint: .top, endPoint: .bottom)))
                .overlay(shape.stroke(LinearGradient(
                    colors: [.white.opacity(contrast == .increased ? 0.4 : 0.13),
                             .white.opacity(contrast == .increased ? 0.3 : 0.04)],
                    startPoint: .top, endPoint: .bottom), lineWidth: 1))
                .shadow(color: .black.opacity(0.45), radius: 18, x: 0, y: 10)
        }
    }
}

extension View {
    /// Card or panel: a raised slab in an 18pt continuous rectangle. Content is
    /// clipped to the shape.
    func sgGlass(radius: CGFloat = SG.Radius.card, highlighted: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return self.clipShape(shape).modifier(SGGlassSurface(shape: shape, highlighted: highlighted))
    }

    /// Pill (segmented track, chip, search field).
    func sgGlassCapsule(highlighted: Bool = false, interactive: Bool = false) -> some View {
        modifier(SGGlassSurface(shape: Capsule(), highlighted: highlighted, interactive: interactive))
    }

    /// Round key or icon button.
    func sgGlassCircle(interactive: Bool = true) -> some View {
        modifier(SGGlassSurface(shape: Circle(), interactive: interactive))
    }

    /// The one card treatment: a raised slab, 18pt radius.
    func sgCard(padding: CGFloat = SG.Space.lg) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .sgGlass()
    }

    /// Row card — same shell, tighter padding; `selected` lifts it.
    func sgRow(selected: Bool = false) -> some View {
        self
            .padding(.horizontal, SG.Space.lg)
            .padding(.vertical, SG.Space.md)
            .sgGlass(highlighted: selected)
    }

    /// The app's one motion curve for state changes, or none with Reduce Motion.
    func sgAnimation<V: Equatable>(_ value: V, reduceMotion: Bool) -> some View {
        animation(reduceMotion ? nil : SG.Motion.spring, value: value)
    }
}

// MARK: - Screen Header

/// Title + subtitle block used at the top of every detail pane.
struct SGScreenHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: SG.Space.xs) {
            Text(title)
                .font(SG.Font.screenTitle)
                .foregroundColor(.white)
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundColor(.sgTextSecondary)
        }
        .padding(.top, SG.Space.xl)
    }
}

// MARK: - Pill Buttons

/// Primary action: a light-grey pill with a dark label.
struct SGPrimaryButton: View {
    let title: String
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(white: 0.1))
                .padding(.horizontal, SG.Space.md)
                .frame(height: 30)
                .background(Capsule().fill(Color(white: 0.86)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.4)
        .disabled(!enabled)
    }
}

/// Secondary action: a dark pill with a light label and a hairline edge.
struct SGSecondaryButton: View {
    let title: String
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color(white: 0.88))
                .padding(.horizontal, SG.Space.md)
                .frame(height: 28)
                .background(Capsule().fill(Color(white: 0.2)))
                .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.4)
        .disabled(!enabled)
    }
}

// MARK: - Skeleton / Loading

/// Placeholder block for content that has been requested but has not arrived.
/// Static on purpose: nothing in the app loops or animates while it waits.
struct SGSkeleton: View {
    var height: CGFloat = 56

    var body: some View {
        RoundedRectangle(cornerRadius: SG.Radius.card, style: .continuous)
            .fill(Color.sgSurface)
            .frame(height: height)
            .accessibilityLabel("Loading")
    }
}

// MARK: - Bars and Gauges

/// Horizontal meter. The filled portion is white, the track is surfaceHigh —
/// no colour thresholds, because a monochrome system cannot say "danger" in red.
struct SGMeter: View {
    /// 0…1
    let value: Double
    var height: CGFloat = 6
    /// White, or a status colour where the level carries meaning (battery).
    var tint: Color = .white

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.sgSurfaceHigh)
                Capsule()
                    .fill(tint)
                    .frame(width: geo.size.width * min(max(value, 0), 1))
            }
        }
        .frame(height: height)
    }
}

/// Circular gauge for a single 0…1 reading, with a large tabular numeral inside.
struct SGRing: View {
    let value: Double
    let label: String
    let caption: String
    var size: CGFloat = 132
    /// White, or a status colour where the reading carries meaning (battery).
    var tint: Color = .white

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.sgSurfaceHigh, lineWidth: 10)
            Circle()
                .trim(from: 0, to: min(max(value, 0), 1))
                .stroke(tint, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(reduceMotion ? nil : SG.Motion.standard, value: value)

            VStack(spacing: 2) {
                Text(label)
                    .font(SG.Font.mono(24, weight: .bold))
                    .foregroundColor(.white)
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : SG.Motion.standard, value: label)
                Text(caption)
                    .font(SG.Font.mono(10))
                    .foregroundColor(.sgTextSecondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(caption) \(label)")
    }
}

// MARK: - Sparkline

/// Thin white polyline over a surfaceHigh baseline. No fill, no gradient —
/// a filled area chart on a near-black canvas reads as a smudge.
struct SGSparkline: View {
    /// Newest sample last. Empty or single-sample input draws just the baseline.
    let samples: [Double]
    var lineWidth: CGFloat = 2

    var body: some View {
        GeometryReader { geo in
            let maxV = max(samples.max() ?? 1, 0.0001)
            ZStack(alignment: .bottom) {
                Rectangle()
                    .fill(Color.sgSurfaceHigh)
                    .frame(height: 1)

                if samples.count > 1 {
                    Path { path in
                        let stepX = geo.size.width / CGFloat(samples.count - 1)
                        for (i, sample) in samples.enumerated() {
                            let x = CGFloat(i) * stepX
                            let y = geo.size.height * (1 - CGFloat(sample / maxV))
                            if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                            else { path.addLine(to: CGPoint(x: x, y: y)) }
                        }
                    }
                    .stroke(Color.white, style: StrokeStyle(lineWidth: lineWidth, lineJoin: .round))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Media Scrubber

/// Waveform-styled seek bar. Click or drag anywhere to seek.
///
/// IMPORTANT, and commented here so nobody mistakes it later: the bar heights are
/// NOT audio amplitude. Android's MediaController exposes no PCM data, so there is
/// no waveform to be had. The heights come from a deterministic hash of the track
/// title, meaning they are stable for a given track and never re-shuffle mid-play.
/// This is a decorative progress affordance in a waveform idiom — not a lie about
/// the audio, and never labelled as one in the UI.
struct MediaScrubber: View {
    let positionMs: Int64
    let durationMs: Int64
    let trackKey: String
    let onSeek: (Int64) -> Void

    private var progress: Double {
        durationMs > 0 ? min(max(Double(positionMs) / Double(durationMs), 0), 1) : 0
    }

    /// Stable pseudo-random heights in 0.25…1.0, seeded by the track title.
    /// Bar count follows the width (one bar per 6pt) so bars stay thin at any
    /// size — a fixed 64 stretched into round blobs on a wide pane.
    private func heights(_ count: Int) -> [Double] {
        var seed = UInt64(abs(trackKey.hashValue) % 1_000_003) &+ 1
        return (0..<count).map { _ in
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return 0.25 + Double((seed >> 33) % 1000) / 1000 * 0.75
        }
    }

    var body: some View {
        GeometryReader { geo in
            let count = max(24, Int(geo.size.width / 6))
            let played = Int((Double(count) * progress).rounded())
            HStack(alignment: .center, spacing: 3) {
                ForEach(Array(heights(count).enumerated()), id: \.offset) { index, height in
                    Capsule()
                        .fill(index < played ? Color.white : Color.white.opacity(0.2))
                        .frame(height: max(3, 28 * height))
                }
            }
            .frame(height: 28)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onEnded { value in
                        guard durationMs > 0, geo.size.width > 0 else { return }
                        let fraction = min(max(value.location.x / geo.size.width, 0), 1)
                        onSeek(Int64(Double(durationMs) * fraction))
                    }
            )
        }
        .frame(height: 28)
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(Int(progress * 100)) percent")
    }
}

// MARK: - Micro-interactions

/// Lifts a row to surfaceHigh while the pointer is over it. The single hover
/// affordance in the app — anything more elaborate reads as noise at this density.
struct SGHoverHighlight: ViewModifier {
    var base: Color = .sgSurface
    var hovered: Color = .sgSurfaceHigh
    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .background(isHovering ? hovered : base)
            .clipShape(RoundedRectangle(cornerRadius: SG.Radius.card))
            .animation(reduceMotion ? nil : SG.Motion.quick, value: isHovering)
            .onHover { isHovering = $0 }
    }
}

extension View {
    func sgHoverRow(base: Color = .sgSurface, hovered: Color = .sgSurfaceHigh) -> some View {
        modifier(SGHoverHighlight(base: base, hovered: hovered))
    }
}

// MARK: - Keyboard Hints

/// Small recessed chip used for ⌘-key hints in the command palette and toolbar.
struct SGKeyHint: View {
    let text: String

    var body: some View {
        Text(text)
            .font(SG.Font.mono(10))
            .foregroundColor(.white.opacity(0.4))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.sgSurfaceHigh)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .accessibilityHidden(true)
    }
}

// MARK: - Empty State

/// The one empty-state treatment for the whole app.
///
/// The illustration is a single oversized outline glyph at white 15% — light
/// enough to read as a watermark rather than content, which is the only way an
/// illustration works on a zero-colour canvas. A filled or higher-contrast mark
/// competes with the real UI and starts to look like a broken image.
///
/// Icon and CTA are both optional: a *transient* empty state (a search with no
/// matches) gets text alone, because there is nothing to act on. A *structural*
/// empty state (nothing paired, no folder shared) gets the full treatment.
struct EmptyStateText: View {
    let message: String
    var glyph: String? = nil
    var actionLabel: String? = nil
    var action: (() -> Void)? = nil

    init(_ message: String,
         glyph: String? = nil,
         actionLabel: String? = nil,
         action: (() -> Void)? = nil) {
        self.message = message
        self.glyph = glyph
        self.actionLabel = actionLabel
        self.action = action
    }

    var body: some View {
        VStack(spacing: SG.Space.lg) {
            if let glyph {
                Image(systemName: glyph)
                    .font(.system(size: 56, weight: .ultraLight))
                    .foregroundColor(.white.opacity(0.15))
                    .accessibilityHidden(true)
            }

            Text(message)
                .font(SG.Font.empty)
                .foregroundColor(.sgTextSecondary)
                .multilineTextAlignment(.center)

            if let actionLabel, let action {
                SGPrimaryButton(title: actionLabel, action: action)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 32)
        .accessibilityElement(children: .combine)
    }
}
