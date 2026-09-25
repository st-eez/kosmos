/// One private focus request for a window, a function for each step of the split model in
/// tla/Kosmos.tla (docs/focus.md).
public struct KeyRequest: Sendable {
    /// Read by the queue at `FocusStart`.
    public let appWasFront: Bool

    public init(appWasFront: Bool) {
        self.appWasFront = appWasFront
    }

    /// A background app's job does nothing, so no raise comes before the key record
    /// (docs/focus.md).
    public func workerStarts(isCurrent: Bool) -> Bool {
        appWasFront && isCurrent
    }

    public func workerRead(isCurrent: Bool, focused: WindowID??, target: WindowID) -> Bool {
        isCurrent && focusGoesAhead(to: target, appIsFront: true, focused: focused)
    }

    /// An app that left the front would only reorder its own windows, and its raise would
    /// land after whatever fronts it next.
    public func workerRaises(isCurrent: Bool, appIsFront: Bool) -> Bool {
        isCurrent && appIsFront
    }

    public func queueKeys(isCurrent: Bool, appIsFront: Bool) -> Bool {
        !appWasFront && isCurrent && !appIsFront
    }

    /// The raise after the key record skips the current-request check (docs/focus.md;
    /// tla/README.md, changes 21 and 23).
    public static func workerPostRaises(appIsFront: Bool, focused: WindowID??, target: WindowID) -> Bool {
        appIsFront && focused == .some(target)
    }
}
