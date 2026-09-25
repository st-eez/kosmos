/// Whether a focus request goes ahead once its app's focused window is read (docs/focus.md).
/// `focused` is nil when the app did not answer, and .some(nil) when it has none.
public func focusGoesAhead(to window: WindowID, appIsFront: Bool, focused: WindowID??) -> Bool {
    guard appIsFront else { return true }
    guard let focused else { return false }
    return focused != window
}
