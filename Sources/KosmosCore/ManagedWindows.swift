/// The windows the inventory has reported managed, so each reported managed gets one report
/// that it is not. A window that leaves level 0 or gains a parent stays managed, as apps such
/// as Helium change a window's level while it lives, and its removal reports it
/// (docs/inventory.md).
public struct ManagedWindows: Sendable {
    private var reported: Set<WindowID> = []

    public init() {}

    /// At each Accessibility read of the window: true when it becomes managed, false when it
    /// stops being, and nil for no change. A standard window that is no candidate waits for the
    /// read the inventory makes when it becomes one.
    public mutating func read(_ id: WindowID, standard: Bool, candidate: Bool) -> Bool? {
        if standard, candidate, reported.insert(id).inserted { return true }
        if !standard, reported.remove(id) != nil { return false }
        return nil
    }

    /// Whether the window's removal reports it unmanaged.
    public mutating func removed(_ id: WindowID) -> Bool {
        reported.remove(id) != nil
    }
}
