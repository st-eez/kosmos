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

    /// Nil while the window is in no Space, as during the transition in and out. The queries
    /// can block during a Space transition, so call it off the main thread.
    public static func isFullscreen(_ window: UInt32) -> Bool? {
        guard let spaces = SkyLight.spaces(of: window), !spaces.isEmpty else { return nil }
        return !current().fullscreenSpaces.isDisjoint(with: spaces)
    }

    public var ordinarySpaces: Set<UInt64> { Set(displays.flatMap(\.ordinarySpaces)) }
    var fullscreenSpaces: Set<UInt64> { Set(displays.flatMap(\.allSpaces).filter { $0.type == 4 }.map(\.id)) }
    var allSpaces: [UInt64] { displays.flatMap(\.allSpaces).map(\.id) }

    /// The main display's choice for a window with no ordinary Space (docs/hiding.md).
    public func ordinarySpace(original: UInt64?) -> UInt64? {
        let main = display(for: CGMainDisplayID()) ?? displays.first
        return Self.ordinarySpace(current: main?.currentSpace, spaces: (main?.ordinarySpaces ?? []) + displays.flatMap(\.ordinarySpaces),
                                  original: original)
    }

    /// The choice on display `id`. A display missing from the Space list, or none, leaves it to
    /// the main display (docs/hiding.md).
    public func ordinarySpace(on id: CGDirectDisplayID?, original: UInt64?) -> UInt64? {
        guard let id, let display = display(for: id),
              let space = Self.ordinarySpace(current: display.currentSpace, spaces: display.ordinarySpaces, original: original)
        else { return ordinarySpace(original: original) }
        return space
    }

    /// `spaces` lists the display's own Spaces first.
    static func ordinarySpace(current: UInt64?, spaces: [UInt64], original: UInt64?) -> UInt64? {
        if let current { return current }
        if let original, spaces.contains(original) { return original }
        return spaces.first
    }

    /// Native fullscreen Spaces and the holding Space are not ordinary, whether or not the
    /// window's Space list names them.
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
