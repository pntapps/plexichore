import AppKit
import SwiftUI

// Port of PlexiChore-Desktop/src/PlexiChore.App/Themes/PlexiTheme.xaml.
// Dark is the Windows look (default); light variants are provided for macOS "Light"/"System" appearance.

extension Color {
    /// #RRGGBB or #AARRGGBB (WPF order).
    init(hex: String) {
        var s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if s.count == 6 { s = "FF" + s }
        let v = UInt64(s, radix: 16) ?? 0
        self.init(.sRGB,
                  red: Double((v >> 16) & 0xFF) / 255,
                  green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255,
                  opacity: Double((v >> 24) & 0xFF) / 255)
    }
}

private func dynamic(dark: String, light: String) -> Color {
    let d = NSColor(Color(hex: dark)), l = NSColor(Color(hex: light))
    return Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark, .aqua, .vibrantLight]).map {
            $0 == .darkAqua || $0 == .vibrantDark
        } == true ? d : l
    })
}

enum Theme {
    // ===== Palette (dark-first, electric violet -> cyan) =====
    static let violetRaw = Color(hex: "#7C4DFF")
    static let cyanRaw = Color(hex: "#00E5FF")

    static let base = dynamic(dark: "#0C0A14", light: "#F4F2FA")
    static let card = dynamic(dark: "#CC17141F", light: "#E6FFFFFF")
    static let cardHover = dynamic(dark: "#E01C1828", light: "#FFFFFFFF")
    static let cardBorder = dynamic(dark: "#1FFFFFFF", light: "#14000000")
    static let subtle = dynamic(dark: "#0DFFFFFF", light: "#0A000000")
    static let subtle2 = dynamic(dark: "#16FFFFFF", light: "#12000000")
    static let text = dynamic(dark: "#F4F2FA", light: "#17141F")
    static let textSecondary = dynamic(dark: "#A9A4BD", light: "#55506A")
    static let textTertiary = dynamic(dark: "#6F6A85", light: "#8A85A0")

    static let violet = violetRaw
    static let violetLight = dynamic(dark: "#B9A3FF", light: "#6A3DF0")
    static let cyan = dynamic(dark: "#00E5FF", light: "#0091A8")
    static let green = dynamic(dark: "#3DDC97", light: "#14A06A")
    static let amber = dynamic(dark: "#FFB547", light: "#C27400")
    static let red = dynamic(dark: "#FF5C7A", light: "#D93355")

    static let greenSoft = Color(hex: "#1F3DDC97")
    static let amberSoft = Color(hex: "#1FFFB547")
    static let redSoft = Color(hex: "#1FFF5C7A")
    static let violetSoft = Color(hex: "#267C4DFF")
    static let cyanSoft = Color(hex: "#1F00E5FF")

    // Plexi.SecondaryButton states: border #24FFFFFF, hover #26FFFFFF, pressed #14FFFFFF.
    static let secondaryBorder = dynamic(dark: "#24FFFFFF", light: "#1F000000")
    static let secondaryHover = dynamic(dark: "#26FFFFFF", light: "#1C000000")
    static let secondaryPressed = dynamic(dark: "#14FFFFFF", light: "#0A000000")

    static let dangerText = dynamic(dark: "#FF8FA3", light: "#C8284A")
    static let errorText = dynamic(dark: "#FFB3C1", light: "#B4233F")
    static let hintText = dynamic(dark: "#FFD9A0", light: "#7A4C00")

    // Hero (always dark, like Windows) text colours.
    static let heroText = Color.white
    static let heroSecondary = Color(hex: "#C9C3E0")
    static let heroTertiary = Color(hex: "#8E88A8")

    // ===== Gradients =====
    static let accentGradient = LinearGradient(colors: [Color(hex: "#7C4DFF"), Color(hex: "#00E5FF")],
                                               startPoint: .topLeading, endPoint: .bottomTrailing)
    static let accentGradientH = LinearGradient(colors: [Color(hex: "#9A6BFF"), Color(hex: "#00E5FF")],
                                                startPoint: .leading, endPoint: .trailing)
    static let accentGradientHover = LinearGradient(colors: [Color(hex: "#9670FF"), Color(hex: "#4DEEFF")],
                                                    startPoint: .topLeading, endPoint: .bottomTrailing)
    static let heroGradient = LinearGradient(stops: [
        .init(color: Color(hex: "#2A1A5E"), location: 0),
        .init(color: Color(hex: "#171334"), location: 0.55),
        .init(color: Color(hex: "#0B2A3A"), location: 1),
    ], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let heroBorder = LinearGradient(stops: [
        .init(color: Color(hex: "#997C4DFF"), location: 0),
        .init(color: Color(hex: "#2200E5FF"), location: 0.5),
        .init(color: Color(hex: "#9900E5FF"), location: 1),
    ], startPoint: .topLeading, endPoint: .bottomTrailing)

    static let mono = Font.system(size: 12, design: .monospaced)

    // Legacy names used by older views.
    static var accent: LinearGradient { accentGradient }
    static var accentHorizontal: LinearGradient { accentGradientH }
    static var success: Color { green }
    static var warning: Color { amber }
    static var danger: Color { red }
}

/// Windows `Tone` strings (good|warn|bad|info|accent|neutral) + ToneToBrushConverter.
enum Tone: String {
    case good, warn, bad, info, accent, neutral

    var color: Color {
        switch self {
        case .good: return Theme.green
        case .warn: return Theme.amber
        case .bad: return Theme.red
        case .info: return Theme.cyan
        case .accent: return Theme.violetLight
        case .neutral: return Theme.textSecondary
        }
    }

    var soft: Color {
        switch self {
        case .good: return Theme.greenSoft
        case .warn: return Theme.amberSoft
        case .bad: return Theme.redSoft
        case .info: return Theme.cyanSoft
        case .accent: return Theme.violetSoft
        case .neutral: return Theme.subtle2
        }
    }
}

// MARK: - Text styles

extension View {
    func plexiPageTitle() -> some View { font(.system(size: 28, weight: .semibold)).foregroundColor(Theme.text) }
    func plexiPageSubtitle() -> some View {
        font(.system(size: 14)).foregroundColor(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true).padding(.top, 4)
    }
    func plexiCardTitle() -> some View { font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.text).lineLimit(1) }
    func plexiBody() -> some View {
        font(.system(size: 13)).foregroundColor(Theme.textSecondary).lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
    }
    func plexiCaption() -> some View {
        font(.system(size: 11.5)).foregroundColor(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
    }
    func plexiBadgeText() -> some View { font(.system(size: 11.5, weight: .semibold)).foregroundColor(Theme.text) }
}

/// "CONNECTED TABLETS" style section header (Plexi.SectionHeader: 13 semibold, margin 4,26,0,10).
struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(Theme.textSecondary)
            .padding(.leading, 4)
            .padding(.top, 26)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Containers

/// Plexi.Card: card brush, 1 px border, radius 16, padding 22,20.
/// `fillHeight` stretches the card to its row like a WPF Grid cell (equal-height card rows).
struct PlexiCard<Content: View>: View {
    var padding: EdgeInsets = EdgeInsets(top: 20, leading: 22, bottom: 20, trailing: 22)
    var cornerRadius: CGFloat = 16
    var fillHeight = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: fillHeight ? .infinity : nil, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(Theme.cardBorder, lineWidth: 1))
    }
}

/// Plexi.SettingRow: radius 12, padding 18,14, bottom margin 6.
struct SettingRow<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        content()
            .padding(.horizontal, 18).padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.cardBorder, lineWidth: 1))
            .padding(.bottom, 6)
    }
}

/// Hero card (gradient + gradient hairline), used on Home, About, USB "get adb".
struct HeroCard<Content: View>: View {
    var cornerRadius: CGFloat = 24
    var padding = EdgeInsets(top: 30, leading: 34, bottom: 30, trailing: 34)
    @ViewBuilder var content: () -> Content
    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(Theme.heroGradient))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(Theme.heroBorder, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .environment(\.colorScheme, .dark)
    }
}

/// Plexi.Tile: subtle fill, radius 12, padding 14,10.
struct StatTile: View {
    let label: String
    let value: String
    var suffix: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased()).font(.system(size: 11)).foregroundColor(Theme.textTertiary).lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(value).font(.system(size: 18, weight: .semibold)).monospacedDigit().foregroundColor(Theme.text)
                if !suffix.isEmpty {
                    Text(suffix).font(.system(size: 13)).foregroundColor(Theme.textTertiary)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.subtle))
    }
}

/// Plexi.IconBubble: 44x44, radius 13, violet-soft fill.
struct IconBubble<Fill: ShapeStyle>: View {
    let systemImage: String
    var size: CGFloat = 44
    var cornerRadius: CGFloat = 13
    var iconSize: CGFloat = 20
    var fill: Fill
    var tint: Color = Theme.violetLight

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(fill)
            Image(systemName: systemImage).font(.system(size: iconSize, weight: .regular)).foregroundColor(tint)
        }
        .frame(width: size, height: size)
    }
}

extension IconBubble where Fill == Color {
    init(systemImage: String, size: CGFloat = 44, cornerRadius: CGFloat = 13, iconSize: CGFloat = 20,
         tone: Tone) {
        self.init(systemImage: systemImage, size: size, cornerRadius: cornerRadius, iconSize: iconSize,
                  fill: tone.soft, tint: tone.color)
    }
}

/// Plexi.Badge: capsule, padding 10,3.
struct Badge: View {
    let text: String
    var systemImage: String? = nil
    var fill: Color = Theme.subtle2
    var tint: Color = Theme.text
    var dot: Color? = nil

    var body: some View {
        HStack(spacing: 5) {
            if let dot { Circle().fill(dot).frame(width: 7, height: 7) }
            if let systemImage { Image(systemName: systemImage).font(.system(size: 10.5, weight: .semibold)) }
            Text(text).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
        }
        .foregroundColor(tint)
        .padding(.horizontal, 10).padding(.vertical, 3)
        .background(Capsule().fill(fill))
    }
}

/// Plexi.StatusChip (hero card): rounded rect with hairline, dot + text.
struct StatusChip: View {
    let text: String
    let tone: Tone
    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(tone.color).frame(width: 7, height: 7)
            Text(text).font(.system(size: 11.5, weight: .semibold)).foregroundColor(.white).lineLimit(1)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(hex: "#14FFFFFF")))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color(hex: "#26FFFFFF"), lineWidth: 1))
    }
}

/// Coloured info / warning / error strip used inside cards.
struct NoticeStrip<Trailing: View>: View {
    let systemImage: String
    let text: String
    let tone: Tone
    var textColor: Color? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            Image(systemName: systemImage).font(.system(size: 14)).foregroundColor(tone.color)
            Text(text).font(.system(size: 13)).foregroundColor(textColor ?? Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            trailing()
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tone == .neutral ? Theme.subtle : tone.soft))
    }
}

extension NoticeStrip where Trailing == EmptyView {
    init(systemImage: String, text: String, tone: Tone, textColor: Color? = nil) {
        self.init(systemImage: systemImage, text: text, tone: tone, textColor: textColor, trailing: { EmptyView() })
    }
}

// MARK: - Buttons

/// Plexi.PrimaryButton: accent gradient, radius 10, padding 18,9, glow on hover.
struct PrimaryButtonStyle: ButtonStyle {
    var fullWidth = false
    var verticalPadding: CGFloat = 9
    func makeBody(configuration: Configuration) -> some View { PrimaryBody(configuration: configuration, fullWidth: fullWidth, vpad: verticalPadding) }

    private struct PrimaryBody: View {
        let configuration: Configuration
        let fullWidth: Bool
        let vpad: CGFloat
        @State private var hover = false
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 18).padding(.vertical, vpad)
                .frame(maxWidth: fullWidth ? .infinity : nil)
                .background(
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.accentGradient)
                            .blur(radius: 10).opacity(hover && enabled ? 0.55 : 0)
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(hover ? Theme.accentGradientHover : Theme.accentGradient)
                    }
                )
                .opacity(!enabled ? 0.35 : (configuration.isPressed ? 0.85 : 1))
                .contentShape(Rectangle())
                .onHover { hover = $0 }
        }
    }
}

/// Plexi.SecondaryButton / Plexi.DangerButton: subtle fill + hairline, radius 10, padding 16,8.
struct SecondaryButtonStyle: ButtonStyle {
    var danger = false
    var fullWidth = false
    var verticalPadding: CGFloat = 8
    func makeBody(configuration: Configuration) -> some View {
        SecondaryBody(configuration: configuration, danger: danger, fullWidth: fullWidth, vpad: verticalPadding)
    }

    private struct SecondaryBody: View {
        let configuration: Configuration
        let danger: Bool
        let fullWidth: Bool
        let vpad: CGFloat
        @State private var hover = false
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            // DangerButton is BasedOn SecondaryButton, so it shares the hover / pressed fills.
            let fill: Color = configuration.isPressed ? Theme.secondaryPressed
                : (hover ? Theme.secondaryHover : (danger ? Color(hex: "#14FF5C7A") : Theme.subtle2))
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(danger ? Theme.dangerText : Theme.text)
                .padding(.horizontal, 16).padding(.vertical, vpad)
                .frame(maxWidth: fullWidth ? .infinity : nil)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(fill))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(danger ? Color(hex: "#33FF5C7A") : Theme.secondaryBorder, lineWidth: 1))
                .opacity(enabled ? 1 : 0.4)
                .contentShape(Rectangle())
                .onHover { hover = $0 }
        }
    }
}

/// Plexi.GhostButton: cyan text link, hover tint.
struct GhostButtonStyle: ButtonStyle {
    var tint: Color = Theme.cyan
    func makeBody(configuration: Configuration) -> some View { GhostBody(configuration: configuration, tint: tint) }

    private struct GhostBody: View {
        let configuration: Configuration
        let tint: Color
        @State private var hover = false
        var body: some View {
            configuration.label
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundColor(tint)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hover ? Color(hex: "#1400E5FF") : .clear))
                .opacity(configuration.isPressed ? 0.7 : 1)
                .contentShape(Rectangle())
                .onHover { hover = $0 }
        }
    }
}

/// Icon + text label used inside buttons (Windows: SymbolIcon + TextBlock, 7-8 px gap).
struct IconLabel: View {
    let text: String
    let systemImage: String
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage).font(.system(size: 12, weight: .semibold))
            Text(text)
        }
    }
}

/// Windows ui:ToggleSwitch equivalent (violet accent when on, also in inactive windows — the native
/// NSSwitch turns grey whenever the window is not key).
struct PlexiToggle: View {
    @Binding var isOn: Bool
    var body: some View {
        Toggle("", isOn: $isOn).toggleStyle(PlexiSwitchStyle()).labelsHidden()
    }
}

struct PlexiSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View { SwitchBody(configuration: configuration) }

    private struct SwitchBody: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var enabled
        @State private var hover = false
        var body: some View {
            let on = configuration.isOn
            ZStack(alignment: on ? .trailing : .leading) {
                Capsule()
                    .fill(on ? AnyShapeStyle(Theme.violet) : AnyShapeStyle(hover ? Theme.subtle2 : Theme.subtle))
                    .overlay(Capsule().strokeBorder(on ? Color.clear : Theme.textTertiary, lineWidth: 1))
                Circle()
                    .fill(on ? Color.white : Theme.textSecondary)
                    .frame(width: on ? 14 : 12, height: on ? 14 : 12)
                    .padding(.horizontal, on ? 3 : 4)
            }
            .frame(width: 40, height: 20)
            .opacity(enabled ? 1 : 0.4)
            .contentShape(Capsule())
            .onTapGesture {
                guard enabled else { return }
                withAnimation(.easeOut(duration: 0.15)) { configuration.isOn.toggle() }
            }
            .onHover { hover = $0 }
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(on ? "On" : "Off")
        }
    }
}

/// Plexi.ThinProgress: 4 pt track (subtle) with the horizontal accent gradient. `value` nil = indeterminate.
struct ThinProgress: View {
    var value: Double? = nil
    @State private var phase: CGFloat = -0.35

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.subtle2)
                if let value {
                    Capsule().fill(Theme.accentGradientH)
                        .frame(width: geo.size.width * CGFloat(min(max(value, 0), 1)))
                } else {
                    Capsule().fill(Theme.accentGradientH)
                        .frame(width: geo.size.width * 0.35)
                        .offset(x: geo.size.width * phase)
                        .onAppear {
                            withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { phase = 1 }
                        }
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 4)
    }
}

// MARK: - Backgrounds & brand

/// Window backdrop: base colour + the two ambient glows of MainWindow.xaml.
struct BrandBackground: View {
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Theme.base
                // 900x700 violet glow, top-left at (-320, -360)
                Circle()
                    .fill(RadialGradient(colors: [Color(hex: "#557C4DFF"), Color(hex: "#007C4DFF")],
                                         center: .center, startRadius: 0, endRadius: 450))
                    .frame(width: 900, height: 900)
                    .scaleEffect(x: 1, y: 700.0 / 900.0)
                    .frame(width: 900, height: 700)
                    .offset(x: -320, y: -360)
                // 1000x800 cyan glow, bottom-right at (+380, +460)
                Circle()
                    .fill(RadialGradient(colors: [Color(hex: "#3300E5FF"), Color(hex: "#0000E5FF")],
                                         center: .center, startRadius: 0, endRadius: 500))
                    .frame(width: 1000, height: 1000)
                    .scaleEffect(x: 1, y: 0.8)
                    .frame(width: 1000, height: 800)
                    .offset(x: geo.size.width - 1000 + 380, y: geo.size.height - 800 + 460)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .clipped()
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// Vector re-drawing of Assets/logo-256.png (rounded gradient square, monitor + tablet).
/// Drawn in a 256-unit space and scaled, so it is crisp at any size (also used to render AppIcon.icns).
struct LogoMark: View {
    var size: CGFloat = 38

    var body: some View {
        Canvas { ctx, canvasSize in
            let k = canvasSize.width / 256
            func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: x * k, y: y * k, width: w * k, height: h * k) }

            // Background squircle
            let bg = Path(roundedRect: r(0, 0, 256, 256), cornerRadius: 58 * k, style: .continuous)
            ctx.fill(bg, with: .linearGradient(Gradient(colors: [Color(hex: "#9C7BFF"), Color(hex: "#5AA2FF"), Color(hex: "#12D6F5")]),
                                               startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 256 * k, y: 256 * k)))

            // Monitor (white outline) + stand
            let white = GraphicsContext.Shading.color(.white)
            let monitor = Path(roundedRect: r(40, 48, 134, 98), cornerRadius: 14 * k, style: .continuous)
            ctx.stroke(monitor, with: white, lineWidth: 11 * k)
            ctx.fill(Path(roundedRect: r(92, 146, 12, 28), cornerRadius: 2 * k), with: white)
            ctx.fill(Path(roundedRect: r(70, 170, 56, 11), cornerRadius: 5.5 * k), with: white)

            // Tablet: light-blue rim, white body, dark gradient screen, home dot
            let rim = Path(roundedRect: r(112, 96, 116, 130), cornerRadius: 24 * k, style: .continuous)
            ctx.fill(rim, with: .color(Color(hex: "#3FA0FF")))
            let body = Path(roundedRect: r(122, 106, 96, 110), cornerRadius: 17 * k, style: .continuous)
            ctx.fill(body, with: white)
            let screen = Path(roundedRect: r(136, 118, 68, 78), cornerRadius: 8 * k, style: .continuous)
            ctx.fill(screen, with: .linearGradient(Gradient(colors: [Color(hex: "#3B2A8F"), Color(hex: "#0E6E8F")]),
                                                   startPoint: CGPoint(x: 136 * k, y: 118 * k),
                                                   endPoint: CGPoint(x: 204 * k, y: 196 * k)))
            ctx.fill(Path(ellipseIn: r(166, 202, 9, 7)), with: .color(Color(hex: "#1B1A4A")))
        }
        .frame(width: size, height: size)
    }
}

/// Text filled with the horizontal accent gradient ("PlexiChore" wordmark, pairing digits).
struct GradientText: View {
    let text: String
    var font: Font
    var body: some View {
        Text(text).font(font).foregroundColor(.clear)
            .overlay(Theme.accentGradientH.mask(Text(text).font(font)))
    }
}
