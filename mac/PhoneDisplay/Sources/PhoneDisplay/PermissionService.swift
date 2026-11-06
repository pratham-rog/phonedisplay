import AppKit
import ApplicationServices
import CoreGraphics

enum PermissionService {
    static var screenRecording: Bool {
        CGPreflightScreenCaptureAccess()
    }

    static var accessibility: Bool {
        AXIsProcessTrusted()
    }

    static func requestScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
    }

    static func requestAccessibility() {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
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

    private static func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }
}
