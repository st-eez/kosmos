import CoreGraphics
import CKosmos

/// The managed displays and their Spaces, from SLSCopyManagedDisplaySpaces.
public struct Displays {
    public struct Display: Sendable {
        public let identifier: String
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

    /// With one display macOS names it "Main" instead of by UUID.
    public var mainCurrentSpace: UInt64? {
        let mainID = CGMainDisplayID()
        return display(for: mainID)?.currentSpace ?? displays.first?.currentSpace
    }

    public func currentSpace(at point: CGPoint) -> UInt64? {
        var id: CGDirectDisplayID = 0, count: UInt32 = 0
        guard CGGetDisplaysWithPoint(point, 1, &id, &count) == .success, count > 0 else { return nil }
        return display(for: id)?.currentSpace
    }

    private func display(for id: CGDirectDisplayID) -> Display? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
              let string = CFUUIDCreateString(nil, uuid) as String? else { return nil }
        return displays.first { $0.identifier == string } ?? displays.first { $0.identifier == "Main" }
    }
}
