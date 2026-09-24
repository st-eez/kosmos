import CoreGraphics
import CKosmos

/// The managed displays and their Spaces, from SLSCopyManagedDisplaySpaces.
public struct Displays {
    public struct Display: Sendable {
        public let identifier: String
        /// Nil while the display shows a Space that is not ordinary, such as native fullscreen.
        public let currentSpace: UInt64?
        public let spaces: [UInt64]
    }

    public let displays: [Display]

    public static func current() -> Displays {
        let raw = SLSCopyManagedDisplaySpaces(SkyLight.connection)?.takeRetainedValue() as? [[String: Any]] ?? []
        return Displays(displays: raw.map { display in
            let current = display["Current Space"] as? [String: Any]
            let ordinary = (display["Spaces"] as? [[String: Any]] ?? []).filter { ($0["type"] as? Int) == 0 }
            return Display(identifier: display["Display Identifier"] as? String ?? "",
                           currentSpace: (current?["type"] as? Int) == 0 ? current?["id64"] as? UInt64 : nil,
                           spaces: ordinary.compactMap { $0["id64"] as? UInt64 })
        })
    }

    /// Whether the window is in a native fullscreen Space. Nil while it is in no Space, as
    /// during the transition in and out, when it has left one Space and not yet joined the
    /// other. The queries can block during a Space transition, so call it off the main
    /// thread.
    public static func isFullscreen(_ window: UInt32) -> Bool? {
        let spaces = Set(kosmos_window_spaces(window) as? [UInt64] ?? [])
        guard !spaces.isEmpty else { return nil }
        // Native fullscreen Spaces are type 4, where ordinary Spaces are type 0.
        let raw = SLSCopyManagedDisplaySpaces(SkyLight.connection)?.takeRetainedValue() as? [[String: Any]] ?? []
        return raw.contains { display in
            (display["Spaces"] as? [[String: Any]] ?? []).contains {
                ($0["type"] as? Int) == 4 && ($0["id64"] as? UInt64).map(spaces.contains) == true
            }
        }
    }

    public var ordinarySpaces: Set<UInt64> { Set(displays.flatMap(\.spaces)) }

    /// The ordinary Space for a window that has none: the main display's current Space,
    /// else the window's `original` Space if it still exists, else the main display's first
    /// ordinary Space. A native fullscreen Space on screen is never one, so a reveal works
    /// while one is shown. Nil only when no ordinary Space exists.
    public func ordinarySpace(original: UInt64?) -> UInt64? {
        let main = display(for: CGMainDisplayID()) ?? displays.first
        return Self.ordinarySpace(current: main?.currentSpace, spaces: (main?.spaces ?? []) + displays.flatMap(\.spaces),
                                  original: original)
    }

    /// The choice itself: `current` is the main display's current Space when it is
    /// ordinary, and `spaces` every ordinary Space, the main display's first.
    static func ordinarySpace(current: UInt64?, spaces: [UInt64], original: UInt64?) -> UInt64? {
        if let current { return current }
        if let original, spaces.contains(original) { return original }
        return spaces.first
    }

    /// Whether the window belongs to an ordinary Space. Native fullscreen Spaces and Kosmos's
    /// holding Space are not ordinary, whether or not the window's Space list names them.
    public func isInOrdinarySpace(_ window: UInt32) -> Bool {
        !ordinarySpaces.isDisjoint(with: (kosmos_window_spaces(window) as? [UInt64]) ?? [])
    }

    public func currentSpace(at point: CGPoint) -> UInt64? {
        var id: CGDirectDisplayID = 0, count: UInt32 = 0
        guard CGGetDisplaysWithPoint(point, 1, &id, &count) == .success, count > 0 else { return nil }
        return display(for: id)?.currentSpace
    }

    /// With one display macOS names it "Main" instead of by UUID.
    private func display(for id: CGDirectDisplayID) -> Display? {
        guard let uuid = DisplayIdentity.uuid(of: id) else { return nil }
        return displays.first { $0.identifier == uuid } ?? displays.first { $0.identifier == "Main" }
    }
}
