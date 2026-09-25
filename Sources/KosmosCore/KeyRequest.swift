/// One private focus request for a window, step for step as the split model in
/// tla/Kosmos.tla takes it, in the model's RaiseKeys case (docs/focus.md). Inside the front
/// app only the worker's raise keys a window, and for a background app only the queue's key
/// record does. Each side records the echo right before its own call that changes the key
/// window. The steps, in order:
///
/// - `FocusStart`: FocusQueue.request.
/// - `WorkerStart`: `workerStarts`.
/// - `WorkerRead`: `workerRead`, after the app's focused window is read.
/// - `WorkerRaise`: `workerRaises`, just before AXRaise.
/// - `FocusDecide`: `queueKeys`, once the job finished or 30 ms passed.
/// - `WorkerPost`: `workerPostRaises`, after the queue's key record.
public struct KeyRequest: Sendable {
    /// Read by the queue at `FocusStart`.
    public let appWasFront: Bool

    public init(appWasFront: Bool) {
        self.appWasFront = appWasFront
    }

    /// A background app's job does nothing: a raise there before the key record keyed a stale
    /// window over a newer activation in TLC (`split-user-bgraise`). The queue still waits on
    /// the job, so its key record follows the app's queued activation reads.
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

    /// The key record leaves the window where it sits in its app's stacking order, so the
    /// worker raises it after. The raise skips the current-request check: a newer request for
    /// the window finds it key and raises nothing (tla/README.md, changes 21 and 23).
    public static func workerPostRaises(appIsFront: Bool, focused: WindowID??, target: WindowID) -> Bool {
        appIsFront && focused == .some(target)
    }
}
