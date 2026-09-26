import CoreGraphics

/// Orders a switch's batches against frame writes (docs/hiding.md). A batch reveals its
/// windows only once their writes have landed, and every later batch waits behind it. A
/// window a batch conceals is written only once that batch is done.
public struct BatchOrder: Sendable {
    public typealias Write = (write: FrameWrite, target: CGRect)

    public struct Batch: Equatable, Sendable {
        public let number: Int
        public let show: [WindowID]
        public let hide: [WindowID]
    }

    /// Oldest first: the first `sent` went to Hiding and are not done, and the rest wait.
    private var batches: [Batch] = []
    private var sent = 0
    private var lastNumber = 0
    /// Each waits for the end of the batch numbered `after`.
    private var held: [WindowID: (write: FrameWrite, target: CGRect, after: Int)] = [:]

    public init() {}

    public var isWaiting: Bool { sent < batches.count }

    /// Before the plan's writes, which wait for it.
    public mutating func add(show: [WindowID], hide: [WindowID]) -> Batch {
        lastNumber += 1
        let batch = Batch(number: lastNumber, show: show, hide: hide)
        batches.append(batch)
        return batch
    }

    /// The writes to send now. One to a window a batch not done conceals waits for the first
    /// such batch, and one to a window whose write waits joins it, so its app takes them in
    /// order.
    public mutating func write(_ writes: [WindowID: Write]) -> [WindowID: Write] {
        var now: [WindowID: Write] = [:]
        for (id, entry) in writes {
            if let waiting = held[id] {
                held[id] = (entry.write.replacing(waiting.write, target: entry.target), entry.target, waiting.after)
            } else if let batch = batches.first(where: { $0.hide.contains(id) }) {
                held[id] = (entry.write, entry.target, batch.number)
            } else {
                now[id] = entry
            }
        }
        return now
    }

    /// The batches to send now, oldest first. The first waiting goes once no window it reveals
    /// is `landing` or has a write waiting for an earlier batch, leaving out a window a later
    /// batch conceals again. A write waiting for a later batch lands after its conceal.
    public mutating func ready(landing: (WindowID) -> Bool) -> [Batch] {
        var ready: [Batch] = []
        while sent < batches.count {
            let batch = batches[sent], later = batches[(sent + 1)...]
            guard !batch.show.contains(where: { id in
                (landing(id) || held[id].map { $0.after < batch.number } == true) && !later.contains { $0.hide.contains(id) }
            }) else { break }
            ready.append(batch)
            sent += 1
        }
        return ready
    }

    /// The writes the batch's end sends. One whose window a later batch conceals waits for it.
    public mutating func done(_ number: Int) -> [WindowID: Write] {
        guard let index = batches.firstIndex(where: { $0.number == number }), index < sent else { return [:] }
        batches.remove(at: index)
        sent -= 1
        var released: [WindowID: Write] = [:]
        for (id, entry) in held where entry.after == number {
            if let batch = batches.first(where: { $0.hide.contains(id) }) {
                held[id]!.after = batch.number
            } else {
                released[id] = (entry.write, entry.target)
                held[id] = nil
            }
        }
        return released
    }
}
