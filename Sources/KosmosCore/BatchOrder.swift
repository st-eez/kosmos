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
    /// The newest batch's, so a batch can tell whether a newer one came.
    public private(set) var lastNumber = 0
    /// Writes to windows a batch not yet done conceals.
    private var held: [WindowID: Write] = [:]

    public init() {}

    public var isWaiting: Bool { sent < batches.count }

    /// The first batch waiting.
    public var next: Batch? { isWaiting ? batches[sent] : nil }

    /// Before the plan's writes, which wait for it.
    public mutating func add(show: [WindowID], hide: [WindowID]) -> Batch {
        lastNumber += 1
        let batch = Batch(number: lastNumber, show: show, hide: hide)
        batches.append(batch)
        return batch
    }

    /// The writes to send now. A write waits while a batch not done conceals its window, and
    /// a later write joins it, so its app takes them in order.
    public mutating func write(_ writes: [WindowID: Write]) -> [WindowID: Write] {
        var now: [WindowID: Write] = [:]
        for (id, entry) in writes {
            if let waiting = held[id] {
                held[id] = (entry.write.replacing(waiting.write, target: entry.target), entry.target)
            } else if conceals(batches[...], id) {
                held[id] = entry
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
        while let batch = next {
            let earlier = batches[..<sent], later = batches[(sent + 1)...]
            guard !batch.show.contains(where: { id in
                (landing(id) || (held[id] != nil && conceals(earlier, id))) && !conceals(later, id)
            }) else { break }
            ready.append(batch)
            sent += 1
        }
        return ready
    }

    /// The writes the batch's end sends: those whose window no batch not done conceals.
    public mutating func done(_ number: Int) -> [WindowID: Write] {
        guard let index = batches.firstIndex(where: { $0.number == number }), index < sent else { return [:] }
        batches.remove(at: index)
        sent -= 1
        let released = held.filter { !conceals(batches[...], $0.key) }
        for id in released.keys { held[id] = nil }
        return released
    }

    private func conceals(_ batches: ArraySlice<Batch>, _ id: WindowID) -> Bool {
        batches.contains { $0.hide.contains(id) }
    }
}
