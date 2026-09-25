/// One private focus request for a window, as the focus queue and the target app's worker
/// take it (DESIGN.md, section 5.4). It follows the split model in tla/Kosmos.tla step for
/// step, and each method names the action it implements. Inside the front app only the
/// worker's raise keys a window, and for a background app only the queue's key record does.
/// Each side records the echo right before its own call that changes the key window, so
/// nothing is ever recorded that must be forgotten later.
///
/// - `FocusStart` (FocusQueue.request): the queue ends a stale or concealed request, reads
///   whether the target's app is front, and hands the app's worker its job.
/// - `WorkerStart`: `workerStarts`.
/// - `WorkerRead`: `workerRead`, after the app's focused window is read.
/// - `WorkerRaise`: `workerRaises`, just before AXRaise.
/// - `FocusDecide`: `queueKeys`, once the job finished or 30 ms passed.
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
    /// raises a background app's window: a raise there lands after anything that fronts the
    /// app meanwhile, and keyed a stale window over a newer activation in TLC. The queue
    /// still waits on that job, so its key record follows the app's queued activation reads.
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
}
