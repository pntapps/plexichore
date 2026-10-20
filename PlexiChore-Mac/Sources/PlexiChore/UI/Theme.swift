import AppKit
import SwiftUI

/// PlexiChore brand: dark, glassy surfaces with a violet → cyan accent gradient.
enum Theme {
    static let violet = Color(red: 0x7C / 255.0, green: 0x4D / 255.0, blue: 0xFF / 255.0)   // #7C4DFF
    static let cyan = Color(red: 0x22 / 255.0, green: 0xD3 / 255.0, blue: 0xEE / 255.0)     // #22D3EE
    static let success = Color(red: 0.30, green: 0.85, blue: 0.55)
    static let warning = Color(red: 1.00, green: 0.74, blue: 0.28)
    static let danger = Color(red: 1.00, green: 0.38, blue: 0.45)

    static let accent = LinearGradient(colors: [violet, cyan], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let accentHorizontal = LinearGradient(colors: [violet, cyan], startPoint: .leading, endPoint: .trailing)

    static let backgroundTop = Color(red: 0.07, green: 0.05, blue: 0.14)
    static let backgroundBottom = Color(red: 0.02, green: 0.03, blue: 0.07)

    static let cardFill = Color.white.opacity(0.055)
    static let cardStroke = Color.white.opacity(0.10)
    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.62)
    static let textTertiary = Color.white.opacity(0.40)
}

/// NSVisualEffectView bridge for real behind-window blur.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blending
        v.state = .active
        v.appearance = NSAppearance(named: .darkAqua)
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blending
    }
}

/// The branded window backdrop: blur + deep gradient + soft violet/cyan glows.
struct BrandBackground: View {
    var body: some View {
        ZStack {
            VisualEffectBackground()
            LinearGradient(colors: [Theme.backgroundTop.opacity(0.92), Theme.backgroundBottom.opacity(0.96)],
                           startPoint: .top, endPoint: .bottom)
            GeometryReader { geo in
                Circle()
                    .fill(Theme.violet.opacity(0.35))
                    .frame(width: geo.size.width * 0.7)
                    .blur(radius: 120)
                    .offset(x: -geo.size.width * 0.25, y: -geo.size.height * 0.35)
                Circle()
                    .fill(Theme.cyan.opacity(0.22))
                    .frame(width: geo.size.width * 0.6)
                    .blur(radius: 120)
                    .offset(x: geo.size.width * 0.55, y: geo.size.height * 0.55)
            }
            .allowsHitTesting(false)
        }
        .ignoresSafeArea()
    }
}

/// Frosted card container.
struct GlassCard<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content()
        }
        .padding(padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Theme.cardFill)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .opacity(0.35)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    LinearGradient(colors: [Color.white.opacity(0.16), Color.white.opacity(0.04)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 1)
        )
    }
}

struct SectionHeader: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold))
                .tracking(1.1)
                .foregroundColor(Theme.textSecondary)
        }
    }
}

/// Small capsule with a status dot.
struct StatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
                .shadow(color: color.opacity(0.8), radius: 4)
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(color.opacity(0.14)))
        .overlay(Capsule().strokeBorder(color.opacity(0.35), lineWidth: 1))
    }
}

/// Primary gradient button.
struct GradientButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                Capsule().fill(Theme.accentHorizontal)
                    .opacity(configuration.isPressed ? 0.75 : 1)
            )
            .shadow(color: Theme.violet.opacity(0.45), radius: configuration.isPressed ? 2 : 8, y: 2)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

/// Secondary glass button.
struct GlassButtonStyle: ButtonStyle {
    var tint: Color = .white
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.14 : 0.08)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
    }
}

/// Brand mark: two overlapping rounded screens filled with the accent gradient.
struct BrandMark: View {
    var size: CGFloat = 36

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(Theme.accent)
                .shadow(color: Theme.violet.opacity(0.6), radius: size * 0.3)
            Image(systemName: "rectangle.on.rectangle")
                .font(.system(size: size * 0.46, weight: .semibold))
                .foregroundColor(.white)
        }
        .frame(width: size, height: size)
    }
}

struct StatTile: View {
    let label: String
    let value: String
    var unit: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(.system(size: 9.5, weight: .bold))
                .tracking(0.8)
                .foregroundColor(Theme.textTertiary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(Theme.textPrimary)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Theme.textSecondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.05)))
    }
}
