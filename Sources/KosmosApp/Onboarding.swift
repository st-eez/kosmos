import AppKit

/// Asks for Accessibility permission and waits for it. macOS has no notification for the
/// grant, so the window checks once a second while it is open.
@MainActor
final class Onboarding: NSObject {
    private let window: NSWindow
    private var timer: Timer?
    private let onGranted: @MainActor () -> Void

    init(onGranted: @escaping @MainActor () -> Void) {
        self.onGranted = onGranted
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 170),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = "Kosmos"
        window.isReleasedWhenClosed = false

        let text = NSTextField(wrappingLabelWithString: """
            Kosmos arranges windows through Accessibility. Turn on Kosmos in \
            System Settings > Privacy & Security > Accessibility, and Kosmos starts on its own.
            """)
        let button = NSButton(title: "Open Accessibility Settings", target: self, action: #selector(openSettings))
        button.keyEquivalent = "\r"
        let stack = NSStackView(views: [text, button])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        window.contentView = stack
        window.center()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)

        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    @objc private func openSettings() {
        // Adds Kosmos to the Accessibility list so the user only has to switch it on.
        // The value of kAXTrustedCheckOptionPrompt, a global var that Swift 6 rejects.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": false] as CFDictionary)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    private func check() {
        guard AXIsProcessTrusted() else { return }
        timer?.invalidate()
        window.close()
        onGranted()
    }
}
