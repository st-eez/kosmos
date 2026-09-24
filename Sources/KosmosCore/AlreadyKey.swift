extension KeyWindow {
    /// Whether this focus target is already key, so the focus queue skips its request and
    /// expects no echo (tla/Kosmos.tla, ExecFocus). It is when its app is the front process
    /// and that app's focused window is the target, or, for `.none`, when the app has no
    /// focused window. `focused` is nil when the app was not asked or did not answer: then
    /// the request goes ahead.
    public func isAlreadyKey(appIsFront: Bool, focused: UInt32??) -> Bool {
        guard appIsFront, let focused else { return false }
        switch self {
        case .window(let id): return focused == id
        case .none: return focused == nil
        }
    }
}
