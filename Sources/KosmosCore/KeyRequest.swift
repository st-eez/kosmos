/// One private focus request for a window, as the focus queue and the target app's worker
/// take it (DESIGN.md, section 5.4). It follows the split model in tla/Kosmos.tla step for
/// step, and each method names the action it implements. Inside the front app only the
/// worker's raise keys a window, and for a background app only the queue's key record does.
/// Each side records the echo right before its own call that changes the key window. Only
/// the raise after a key record, which changes it only when the user keyed another window of
/// the app first, has its record forgotten once the raise is done.
///
/// - `FocusStart` (FocusQueue.request): the queue ends a stale or concealed request, reads
///   whether the target's app is front, and hands the app's worker its job.
/// - `WorkerStart`: `workerStarts`.
/// - `WorkerRead`: `workerRead`, after the app's focused window is read.
/// - `WorkerRaise`: `workerRaises`, just before AXRaise.
/// - `FocusDecide`: `queueKeys`, once the job finished or 30 ms passed.
/// - `WorkerPost`: `workerPostRaises`, after the queue's key record.
///
/// This is the model's RaiseKeys case, where AXRaise alone keys the target inside the front
/// app, as it did in 20 of 20 trials of `kosmos-probe keying`. The model's `WorkerKey` step,
/// which records and posts the key record after a raise that does not key, is left out.
public struct KeyRequest: Sendable {
    /// Whether the target's app was the front process when the queue took the request.
    public let appWasFront: Bool

    public init(appWasFront: Bool) {
        self.appWasFront = appWasFront
    }

    /// `WorkerStart`: a stale request ends, and so does a background app's job. Nothing
    /// raises a background app's window before the key record: a raise there lands after
    /// anything that fronts the app meanwhile, and keyed a stale window over a newer
    /// activation in TLC (`split-user-bgraise`). The queue still waits on that job, so its key
    /// record follows the app's queued activation reads.
    public func workerStarts(isCurrent: Bool) -> Bool {
        appWasFront && isCurrent
    }

    /// `WorkerRead`: a stale request ends, and so does one whose target is the app's focused
    /// window, which is key already, or whose app did not answer the read
    /// (focusGoesAhead).
    public func workerRead(isCurrent: Bool, focused: UInt32??, target: UInt32) -> Bool {
        isCurrent && focusGoesAhead(to: target, appIsFront: true, focused: focused)
    }

    /// `WorkerRaise`, just before AXRaise: a current request whose app is still front
    /// records and raises. An app that left the front meanwhile would only reorder its own
    /// windows, and its raise would land after whatever fronts it next.
    public func workerRaises(isCurrent: Bool, appIsFront: Bool) -> Bool {
        isCurrent && appIsFront
    }

    /// `FocusDecide`: the queue keys only a request for a background app, still current,
    /// whose app has not come front meanwhile. It records and posts the key record, which
    /// activates the app with the named window.
    public func queueKeys(isCurrent: Bool, appIsFront: Bool) -> Bool {
        !appWasFront && isCurrent && !appIsFront
    }

    /// `WorkerPost`: after the queue's key record, which leaves the window where it sits in
    /// its app's stacking order, the app's worker raises it, only while the app is front and
    /// the window is its focused window. The raise then keys nothing, unless the user keyed
    /// another window of the app between the read and the raise, and it never raises over a
    /// window the user chose since. It does not check that the request is current: a newer
    /// request for the same window finds it key and raises nothing, and the window would stay
    /// behind its app's other windows (tla/README.md, changes 21 and 23).
    public static func workerPostRaises(appIsFront: Bool, focused: UInt32??, target: UInt32) -> Bool {
        appIsFront && focused == .some(target)
    }
}
