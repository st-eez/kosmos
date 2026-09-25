import AppKit
import Synchronization

/// The window an empty workspace keys, so keystrokes reach no hidden window. An app with a
/// concealed window keys that window when fronted, and only the private key record keys this
/// one (docs/focus.md).
final class EmptyWorkspaceWindow: NSWindow {
    /// What the focus queue needs of the window, from any thread.
    final class Target: Sendable {
        let window: UInt32
        /// Whether the window is key, as its last key change on the main actor said.
        let isKey = Atomic<Bool>(false)

        init(window: UInt32) { self.window = window }
    }

    private(set) var target: Target!
    /// The key window report for an empty workspace, as no worker reports Kosmos's windows.
    var onKey: (@MainActor (ContinuousClock.Instant) -> Void)?

    override var canBecomeKey: Bool { true }

    init() {
        let origin = NSScreen.screens.first?.frame.origin ?? .zero
        super.init(contentRect: NSRect(origin: origin, size: NSSize(width: 1, height: 1)),
                   styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        alphaValue = 0
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        isReleasedWhenClosed = false
        orderFrontRegardless()
        target = Target(window: UInt32(windowNumber))
    }

    /// `display` is in Accessibility's coordinates. Keying the window makes its display the
    /// active one, so it sits on the empty workspace's display (docs/focus.md).
    func place(on display: CGRect) {
        guard !NSScreen.screens.isEmpty else { return }
        let origin = NSScreen.flipped(display).origin
        if frame.origin != origin { setFrameOrigin(origin) }
    }

    override func becomeKey() {
        super.becomeKey()
        target.isKey.store(true, ordering: .relaxed)
        onKey?(.now)
    }

    override func resignKey() {
        super.resignKey()
        target.isKey.store(false, ordering: .relaxed)
    }

    // Kosmos has no main menu, so a key no responder takes would beep.
    override func keyDown(with event: NSEvent) {}

    override func performKeyEquivalent(with event: NSEvent) -> Bool { true }
}
