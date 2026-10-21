import AppKit
import Combine
import SwiftUI

/// Port of Views/PairingWindow.xaml: floating approval card for an unknown Wi-Fi tablet.
/// Exactly one decision is made: Approve, Reject, close (×/Esc) or the 60 s timeout (= reject).
struct PairingWindowView: View {
    let pairing: PendingPairing
    /// (approve, rememberDevice)
    let onDecision: (Bool, Bool) -> Void

    @State private var remember = true
    @State private var remaining = 60
    @State private var answered = false
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                LogoMark(size: 22)
                Text("PlexiChore · New connection").font(.system(size: 12.5, weight: .semibold)).foregroundColor(Color(hex: "#B5AED0"))
                Spacer()
                Button { answer(false) } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).padding(6)
                }
                .buttonStyle(GhostButtonStyle(tint: Color(hex: "#6F6A85")))
                .keyboardShortcut(.cancelAction)
            }

            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Theme.accentGradient)
                    .shadow(color: Color(hex: "#B37C4DFF"), radius: 14)
                Image(systemName: "ipad.landscape").font(.system(size: 32)).foregroundColor(.white)
            }
            .frame(width: 72, height: 72)
            .padding(.top, 22)

            Text(pairing.deviceName.isEmpty ? "A tablet" : pairing.deviceName)
                .font(.system(size: 22, weight: .semibold)).foregroundColor(.white)
                .lineLimit(1).truncationMode(.tail)
                .padding(.top, 16)
            Text("wants to use this Mac as a display over Wi‑Fi")
                .font(.system(size: 13.5)).foregroundColor(Theme.heroSecondary).padding(.top, 4)
            if !pairing.model.isEmpty || !pairing.address.isEmpty {
                Text([pairing.model, pairing.address].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 11.5)).foregroundColor(Theme.heroTertiary).padding(.top, 2)
            }

            Text("Make sure the tablet shows the same code")
                .font(.system(size: 12)).foregroundColor(Theme.heroTertiary)
                .padding(.top, 22).padding(.bottom, 10)
            HStack(spacing: 10) {
                ForEach(Array(pairing.code.enumerated()), id: \.offset) { _, ch in
                    GradientText(text: String(ch), font: .system(size: 34, weight: .bold))
                        .frame(width: 58, height: 68)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(hex: "#1FFFFFFF")))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color(hex: "#33FFFFFF"), lineWidth: 1))
                }
            }

            Toggle("Trust this tablet next time", isOn: $remember)
                .toggleStyle(.checkbox)
                .foregroundColor(Theme.heroSecondary)
                .padding(.top, 22)

            HStack(spacing: 12) {
                Button("Reject") { answer(false) }
                    .buttonStyle(SecondaryButtonStyle(fullWidth: true, verticalPadding: 12))
                Button { answer(true) } label: { IconLabel(text: "Approve", systemImage: "checkmark") }
                    .buttonStyle(PrimaryButtonStyle(fullWidth: true, verticalPadding: 12))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 20)

            Text("Expires in \(remaining) s").font(.system(size: 11.5)).foregroundColor(Color(hex: "#6F6A85")).padding(.top, 14)
        }
        .padding(.horizontal, 30).padding(.top, 26).padding(.bottom, 26)
        .frame(width: 440 - 48)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Theme.heroGradient)
                .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Theme.heroBorder, lineWidth: 1.2))
                .shadow(color: Color(hex: "#9905030C"), radius: 15, x: 0, y: 8)
        )
        .padding(24)
        .environment(\.colorScheme, .dark)
        .onReceive(timer) { _ in
            guard !answered else { return }
            remaining -= 1
            if remaining <= 0 { answer(false) }
        }
    }

    private func answer(_ approve: Bool) {
        guard !answered else { return }
        answered = true
        onDecision(approve, remember)
    }
}
