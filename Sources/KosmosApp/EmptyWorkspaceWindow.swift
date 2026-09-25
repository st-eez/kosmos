import AppKit
import Synchronization

/// The window an empty workspace keys, so keystrokes reach no hidden window (DESIGN.md,
/// section 5.4). An app fronted with every window concealed keyed one of them, fronted with
/// no window brought forward or not, so no app with a concealed window can be the target.
/// Kosmos cannot activate itself either; the focus queue keys this window by the private
/// path, which a background accessory app did for a window of its own in 10 of 10 trials
/// (`kosmos-probe keying`, September 24, 2026).
///
/// It is 1 by 1 point at the bottom left corner of the display it is placed on, borderless,
/// clear and transparent, ignores the mouse, joins every Space and stays out of the window
/// cycle and Mission Control. The inventory tracks only regular apps' windows, and Kosmos
/// is an accessory app, so Kosmos never manages or conceals it. It swallows every key and
/// key equivalent: Kosmos has no main menu, and a key no responder takes would beep.
/// Kosmos's hotkeys are Carbon hotkeys, which fire before the key reaches any window.
final class EmptyWorkspaceWindow: NSWindow {
    /// What the focus queue needs of the window, from any thread.
    final class Target: Sendable {
        let window: UInt32
        /// Whether the window is key, as its last key change on the main actor said.
        let isKey = Atomic<Bool>(false)

        init(window: UInt32) { self.window = window }
    }

    private(set) var target: Target!
    /// Called when the window becomes key, with when: the key window report for an empty
    /// workspace, as Kosmos has no worker reporting its own windows.
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

    /// Moves the window to the bottom left corner of `display`, given in the top left origin
    /// coordinates Accessibility uses. With displays that have separate Spaces, keying the
    /// window makes its display the active one, which takes the menu bar and the next new
    /// window, so it sits on the display the empty workspace is on.
    func place(on display: CGRect) {
        guard let primary = NSScreen.screens.first else { return }
        let origin = NSPoint(x: display.minX, y: primary.frame.height - display.maxY)
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

    override func keyDown(with event: NSEvent) {}

    override func performKeyEquivalent(with event: NSEvent) -> Bool { true }
}
