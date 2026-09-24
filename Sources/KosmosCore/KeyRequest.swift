/// One private focus request for a window, shared by the focus queue and the target app's
/// worker under one lock (DESIGN.md, section 5.4). It follows the split model in
/// tla/Kosmos.tla step for step, and each method names the action it implements. Each side
/// records the echo right before its own call that changes the key window, and never for
/// the other side's call, so nothing is ever recorded that must be forgotten later.
///
/// - `FocusStart` (FocusQueue.request): the queue ends a stale or concealed request, reads
///   whether the target's app is front, creates this request and hands the worker its job.
/// - `WorkerStart`: `workerStarts`.
/// - `WorkerRead`: `workerRead`, after the app's focused window is read when it was front.
/// - `WorkerRaise`: `workerRaises`, just before AXRaise.
/// - `FocusDecide`: `queueDecides`, once the job finished or 30 ms passed.
///
/// This is the model's RaiseKeys case, where AXRaise alone keys the target inside the front
/// app. The model's `WorkerKey` step, which records and posts the key record after the raise
/// when the raise does not key, is left out until `kosmos-probe keying` shows it is needed
/// (tla/README.md on the hover branch, change 11).
public struct KeyRequest<Stamp: Sendable>: Sendable {
    public enum Phase: Equatable, Sendable {
        case pending
        /// The worker records and raises: inside the front app only the raise keys a window.
        case raising
        /// The queue records and posts the key record, which activates a background app with
        /// the named window.
        case sent
    }

    public enum RaiseStep: Sendable {
        case stop
        /// Record with this stamp, then raise.
        case recordAndRaise(Stamp)
        /// Raise without a record: in a background app the raise changes only the app's own
        /// focused window, and the queue's key record keys it.
        case raise
    }

    /// Whether the target's app was the front process when the queue took the request.
    public let appWasFront: Bool
    public private(set) var phase: Phase = .pending

    public init(appWasFront: Bool) {
        self.appWasFront = appWasFront
    }

    /// `WorkerStart`: a stale request ends.
    public func workerStarts(isCurrent: Bool) -> Bool {
        isCurrent
    }

    /// `WorkerRead`: a stale request ends, and so does one whose app was front with the
    /// target as its focused window, which is key already, or which did not answer the read
    /// (KeyWindow.goesAhead). `focused` is the read, made only when the app was front.
    public func workerRead(isCurrent: Bool, focused: UInt32??, target: UInt32) -> Bool {
        isCurrent && KeyWindow.window(target).goesAhead(appIsFront: appWasFront, focused: focused)
    }

    /// `WorkerRaise`, under the lock just before AXRaise. A stale request, or one the queue
    /// has keyed, raises nothing. In the front app the raise keys the window, so the worker
    /// records first and tells the queue it is keying.
    public mutating func workerRaises(isCurrent: Bool, appIsFront: Bool, now: Stamp) -> RaiseStep {
        guard isCurrent, phase != .sent else { return .stop }
        guard appIsFront else { return .raise }
        phase = .raising
        return .recordAndRaise(now)
    }

    /// `FocusDecide`. For a front app the queue only moves on. For a background app, unless
    /// the request went stale, the app came front meanwhile, or the worker is keying it,
    /// the queue records and posts the key record. Returns the record's stamp, or nil.
    public mutating func queueDecides(isCurrent: Bool, appIsFront: Bool, now: Stamp) -> Stamp? {
        guard !appWasFront, isCurrent, !appIsFront, phase != .raising else { return nil }
        phase = .sent
        return now
    }
}

extension KeyRequest.RaiseStep: Equatable where Stamp: Equatable {}
