import CoreGraphics
import CKosmos

/// The managed displays and their Spaces, from SLSCopyManagedDisplaySpaces, whose private
/// keys only `init(raw:)` reads.
public struct Displays: Sendable {
    public struct Space: Sendable, Equatable {
        public let id: UInt64
        /// 0 for an ordinary Space, 4 for a native fullscreen one.
        public let type: Int?
    }

    public struct Display: Sendable {
        public let identifier: String
        /// Nil while the display shows a Space that is not ordinary, such as native fullscreen.
        public let currentSpace: UInt64?
        /// Every Space, in WindowServer's order.
        public let allSpaces: [Space]

        public var ordinarySpaces: [UInt64] { allSpaces.filter { $0.type == 0 }.map(\.id) }
    }

    public let displays: [Display]

    public static func current() -> Displays {
        Displays(raw: SLSCopyManagedDisplaySpaces(SkyLight.connection)?.takeRetainedValue() as? [[String: Any]] ?? [])
    }

    init(raw: [[String: Any]]) {
        func space(_ entry: [String: Any]) -> Space? {
            (entry["id64"] as? UInt64).map { Space(id: $0, type: entry["type"] as? Int) }
        }
        displays = raw.map { display in
            let current = (display["Current Space"] as? [String: Any]).flatMap(space)
            return Display(identifier: display["Display Identifier"] as? String ?? "",
                           currentSpace: current?.type == 0 ? current?.id : nil,
                           allSpaces: (display["Spaces"] as? [[String: Any]] ?? []).compactMap(space))
        }
    }

    /// Whether the window is in a native fullscreen Space. Nil while it is in no Space, as
    /// during the transition in and out, when it has left one Space and not yet joined the
    /// other. The queries can block during a Space transition, so call it off the main
    /// thread.
    public static func isFullscreen(_ window: UInt32) -> Bool? {
        guard let spaces = SkyLight.spaces(of: window), !spaces.isEmpty else { return nil }
        return !current().fullscreenSpaces.isDisjoint(with: spaces)
    }

    public var ordinarySpaces: Set<UInt64> { Set(displays.flatMap(\.ordinarySpaces)) }
    var fullscreenSpaces: Set<UInt64> { Set(displays.flatMap(\.allSpaces).filter { $0.type == 4 }.map(\.id)) }
    var allSpaces: [UInt64] { displays.flatMap(\.allSpaces).map(\.id) }

    /// The ordinary Space for a window that has none: the main display's current Space,
    /// else the window's `original` Space if it still exists, else the main display's first
    /// ordinary Space. A native fullscreen Space on screen is never one, so a reveal works
    /// while one is shown. Nil only when no ordinary Space exists.
    public func ordinarySpace(original: UInt64?) -> UInt64? {
        let main = display(for: CGMainDisplayID()) ?? displays.first
        return Self.ordinarySpace(current: main?.currentSpace, spaces: (main?.ordinarySpaces ?? []) + displays.flatMap(\.ordinarySpaces),
                                  original: original)
    }

    /// The ordinary Space for a window with none that is revealed on the display `id`: that
    /// display's current Space, else the window's `original` Space if that display has it,
    /// else that display's first ordinary Space (docs/hiding.md). A display missing
    /// from the Space list, or none given, leaves the choice to `ordinarySpace(original:)`.
    public func ordinarySpace(on id: CGDirectDisplayID?, original: UInt64?) -> UInt64? {
        guard let id, let display = display(for: id),
              let space = Self.ordinarySpace(current: display.currentSpace, spaces: display.ordinarySpaces, original: original)
        else { return ordinarySpace(original: original) }
        return space
    }

    /// The choice itself: `current` is the display's current Space when it is ordinary, and
    /// `spaces` every ordinary Space to choose from, the display's first.
    static func ordinarySpace(current: UInt64?, spaces: [UInt64], original: UInt64?) -> UInt64? {
        if let current { return current }
        if let original, spaces.contains(original) { return original }
        return spaces.first
    }

    /// Whether the window belongs to an ordinary Space. Native fullscreen Spaces and Kosmos's
    /// holding Space are not ordinary, whether or not the window's Space list names them. A
    /// window whose Spaces do not read is in none.
    public func isInOrdinarySpace(_ window: UInt32) -> Bool {
        SkyLight.spaces(of: window).map { !ordinarySpaces.isDisjoint(with: $0) } ?? false
    }

    public func currentSpace(at point: CGPoint) -> UInt64? {
        var id: CGDirectDisplayID = 0, count: UInt32 = 0
        guard CGGetDisplaysWithPoint(point, 1, &id, &count) == .success, count > 0 else { return nil }
        return display(for: id)?.currentSpace
    }

    private func display(for id: CGDirectDisplayID) -> Display? { display(uuid: DisplayIdentity.uuid(of: id)) }

    /// With one display macOS names it "Main" instead of by UUID.
    func display(uuid: String?) -> Display? {
        guard let uuid else { return nil }
        return displays.first { $0.identifier == uuid } ?? displays.first { $0.identifier == "Main" }
    }
}
