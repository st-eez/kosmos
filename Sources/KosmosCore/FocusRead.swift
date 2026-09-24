extension KeyWindow {
    /// Whether a focus request for this target goes ahead once its app's focused window was
    /// read (tla/Kosmos.tla, WorkerRead, and FocusStart for `.none`). A request for an app
    /// that is not front goes ahead unread. For the front app, `focused` is its focused
    /// window, nil inside when it has none and nil outside when the app did not answer. The
    /// target is key already when it is that window, or for `.none` when the app has none.
    ///
    /// A read with no answer stops the request. The read and the raise go to the same app
    /// with the same timeout, so the app is not answering, and a record for a call that
    /// changes nothing would swallow a later click on the window: going ahead failed TLC's
    /// user configs, where the model's reads always answer (kosmos-hover).
    public func goesAhead(appIsFront: Bool, focused: UInt32??) -> Bool {
        guard appIsFront else { return true }
        guard let focused else { return false }
        switch self {
        case .window(let id): return focused != id
        case .none: return focused != nil
        }
    }
}
