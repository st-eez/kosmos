import AppKit
import CKosmos
import KosmosCore
import KosmosSkyLight

/// Reads of the user's input and the key window's holder (docs/focus-follows-mouse.md).
@MainActor
enum UserInput {
    /// At the Dock's level, where its icons are, and not its menus, Mission Control or
    /// Launchpad. With autohide the Dock's window can span its display, so its frame says nothing.
    static func isDock(_ window: Int) -> Bool {
        guard window > 0, let row = SkyLight.rows([WindowID(window)]).first else { return false }
        return row.level == CGWindowLevelForKey(.dockWindow)
            && NSRunningApplication(processIdentifier: row.pid)?.bundleIdentifier == "com.apple.dock"
    }

    /// A tab dragged out of its group is admitted while the drag goes on, which Kosmos's own
    /// drag state does not cover.
    static var leftButtonDown: Bool { NSEvent.pressedMouseButtons & 1 != 0 }

    static func userPressedJustBefore() -> Bool {
        min(secondsSince(.keyDown), secondsSince(.leftMouseDown), secondsSince(.rightMouseDown)) < 1
    }

    /// Reading the session's event state takes no event tap.
    static func secondsSince(_ type: CGEventType) -> Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: type)
    }

    /// Raycast, Spotlight, Notification Center and Control Center hold the key window while
    /// another app stays front, and a focus would close their panels (docs/focus-follows-mouse.md).
    static func keyHolderApartFromFront() -> pid_t? {
        let front = kosmos_front_pid(), holder = kosmos_key_focus_pid()
        return front != 0 && holder != 0 && holder != front && holder != getpid() ? holder : nil
    }
}
