import AppKit
import KosmosCore
import Synchronization

/// The window an empty workspace keys, so keystrokes reach no hidden window (docs/focus.md).
/// Each display has its own, never moved: a move from the main actor can reach WindowServer
/// after the focus queue's key record.
final class EmptyWorkspaceWindow: NSWindow {
    /// What the focus queue needs of the window, from any thread.
    final class Target: Sendable {
        let window: WindowID
        /// Whether the window is key, as its last key change on the main actor said.
        let isKey = Atomic<Bool>(false)
        /// For Kosmos in front, where the key record keys nothing (docs/focus.md).
        let makeKey: @MainActor @Sendable () -> Void

        init(window: WindowID, makeKey: @escaping @MainActor @Sendable () -> Void) {
            self.window = window
            self.makeKey = makeKey
        }
    }

    private(set) var target: Target!
    /// The key window report for an empty workspace, as no worker reports Kosmos's windows.
    var onKey: (@MainActor (ContinuousClock.Instant) -> Void)?

    override var canBecomeKey: Bool { true }

    /// `display` is in Accessibility's coordinates.
    init(display: CGRect) {
        super.init(contentRect: NSRect(origin: Self.corner(of: display), size: NSSize(width: 1, height: 1)),
                   styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        alphaValue = 0
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        isReleasedWhenClosed = false
        orderFrontRegardless()
        target = Target(window: WindowID(windowNumber)) { [weak self] in self?.makeKey() }
    }

    func isPlaced(on display: CGRect) -> Bool { frame.origin == Self.corner(of: display) }

    private static func corner(of display: CGRect) -> CGPoint { NSScreen.flipped(display).origin }

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
