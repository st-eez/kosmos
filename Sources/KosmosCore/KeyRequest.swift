/// One private focus request, decided together by the focus queue and the app's worker
/// under one lock (DESIGN.md, section 5.4). The worker checks the generation, reads the
/// app's focused window and raises the target; the queue waits for it at most 30 ms, then
/// posts the key record. Whichever side moves the request out of `pending` first decides
/// it, so neither acts on an outcome the other has already overtaken.
public struct KeyRequest<Stamp: Sendable>: Sendable {
    public enum Phase: Sendable {
        case pending
        /// The echo is recorded with this stamp, and the request finishes.
        case recorded(Stamp)
        /// Stale, or the target key already: nothing is recorded or keyed.
        case skipped
    }

    public enum WorkerStep: Sendable {
        case stop
        /// Post the record with this stamp, then raise.
        case record(Stamp)
        /// The queue recorded already: raise, so the request finishes.
        case raise
        /// The queue recorded and keyed already, and the target was key: forget the record,
        /// for no echo will come.
        case drop(Stamp)
    }

    public private(set) var phase: Phase = .pending

    public init() {}

    /// The worker's job starts. Returns whether it reads on. While pending, a stale request
    /// is skipped; once the queue has recorded, the request finishes whatever came since.
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

    /// The worker has read whether the target is key already.
    public mutating func workerRead(alreadyKey: Bool, now: Stamp) -> WorkerStep {
        switch phase {
        case .pending:
            if alreadyKey {
                phase = .skipped
                return .stop
            }
            phase = .recorded(now)
            return .record(now)
        case .recorded(let stamp):
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
