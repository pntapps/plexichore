import AppKit
import ApplicationServices
import CoreGraphics

/// Screen Recording + Accessibility permission helpers.
enum Permissions {
    static var screenRecordingGranted: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows the system prompt the first time; afterwards macOS only allows enabling in Settings.
    @discardableResult
    static func requestScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    /// Shows the system "would like to control this computer" prompt if not yet trusted.
    @discardableResult
    static func requestAccessibility() -> Bool {
        // Literal value of kAXTrustedCheckOptionPrompt (avoids the Unmanaged/CFString import
        // differences between SDK versions).
        let key = "AXTrustedCheckOptionPrompt"
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openScreenRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openLocalNetworkSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")
    }

    private static func open(_ s: String) {
        if let url = URL(string: s) { NSWorkspace.shared.open(url) }
    }
}
