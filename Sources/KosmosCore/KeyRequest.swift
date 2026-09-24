/// One private focus request, decided together by the focus queue and the app's worker
/// under one lock (DESIGN.md, section 5.4). Whichever side moves the request out of
/// `pending` first decides it, so neither acts on an outcome the other has overtaken.
///
/// The steps, in the order a model of the queue and worker split would take them:
/// 1. The queue checks the generation and whether the target's app is the front process,
///    then hands the worker one job and waits for it at most 30 ms.
/// 2. `workerStarts`: before its read, the job skips a request that is stale while pending.
/// 3. The job reads the app's focused window when the app was front.
/// 4. `workerDecides`: right before the raise, with the generation checked again, the job
///    records the echo and raises, skips the request, or settles one the queue recorded.
/// 5. `queueDecides`: when the job answers or 30 ms pass, the queue records the echo itself
///    if the request is still pending, and posts the key record unless it was skipped.
public struct KeyRequest<Stamp: Sendable>: Sendable {
    public enum Phase: Sendable {
        case pending
        /// The echo is recorded with this stamp, and the queue posts the key record.
        case recorded(Stamp)
        /// Stale, or the target key already: nothing is recorded or keyed.
        case skipped
    }

    public enum WorkerStep: Sendable {
        case stop
        /// Post the record with this stamp, then raise.
        case record(Stamp)
        /// The queue recorded already, and the request is current: raise, so the request
        /// finishes, since in the front app the key record alone keys nothing.
        case raise
        /// The queue recorded and keyed already, and no echo will come: forget the record.
        case drop(Stamp)
    }

    public private(set) var phase: Phase = .pending

    public init() {}

    /// The worker's job starts. Returns whether it reads on: a request stale while pending
    /// is skipped before a read that can be slow.
    public mutating func workerStarts(isCurrent: Bool) -> Bool {
        switch phase {
        case .pending:
            guard isCurrent else {
                phase = .skipped
                return false
            }
            return true
        case .recorded: return true
        case .skipped: return false
        }
    }

    /// Right before the raise. `isCurrent` is checked after the read, which can be slow;
    /// `appWasFront` says the target's app was the front process when the queue looked.
    ///
    /// A request the queue recorded and then found stale is never raised: a newer request
    /// has keyed its own target, and a raise could report this window key and be adopted
    /// against it. When the app was front, the key record keyed nothing and no echo will
    /// come, so the record is forgotten; otherwise the record keyed the target, and its echo
    /// clears the record.
    public mutating func workerDecides(isCurrent: Bool, alreadyKey: Bool, appWasFront: Bool, now: Stamp) -> WorkerStep {
        switch phase {
        case .pending:
            guard isCurrent, !alreadyKey else {
                phase = .skipped
                return .stop
            }
            phase = .recorded(now)
            return .record(now)
        case .recorded(let stamp):
            guard isCurrent else { return appWasFront ? .drop(stamp) : .stop }
            return alreadyKey ? .drop(stamp) : .raise
        case .skipped:
            return .stop
        }
    }

    /// The queue is done waiting, answered or not. Returns the stamp to key with, and
    /// whether the queue records it itself, or nil when the worker skipped the request.
    public mutating func queueDecides(now: Stamp) -> (stamp: Stamp, recordsItself: Bool)? {
        switch phase {
        case .pending:
            phase = .recorded(now)
            return (now, true)
        case .recorded(let stamp): return (stamp, false)
        case .skipped: return nil
        }
    }
}

extension KeyRequest.WorkerStep: Equatable where Stamp: Equatable {}
