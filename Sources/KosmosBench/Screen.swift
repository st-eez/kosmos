/// The frames as they arrive, and a step's from the frame before its command until the screen
/// settles after it. A frame that differs from the one before it by fewer than
/// `Picture.least` pixels is dropped, so each kept frame is a change.
public struct Screen: Sendable {
    /// The screen has settled once nothing changed for this long, a margin over the 1 or 2
    /// refreshes between the end of a slide and its write landing.
    public static let quiet = 0.4
    /// A step settles no sooner than this after its send, so a slow start is not taken for
    /// a settled screen.
    public static let shortest = 0.6
    /// A step with no change by then is over.
    public static let unchanged = 1.5
    /// A step still changing then is cut off, and so is one past `most` frames.
    public static let longest = 4.0
    /// At 864 by 542 pixels a frame takes 1.9 MB, so a step holds 450 MB at most.
    public static let most = 240

    public enum Settle: String, Sendable {
        case settled, unchanged, cut
    }

    public private(set) var latest: Picture?
    public private(set) var changedAt = -Double.infinity
    private var step: [Picture]?
    private var overflowed = false

    public init() {}

    public mutating func add(_ picture: Picture) {
        if let latest, picture.differences(from: latest) < Picture.least { return }
        (latest, changedAt) = (picture, picture.time)
        guard step != nil else { return }
        if step!.count < Self.most + 1 { step!.append(picture) } else { overflowed = true }
    }

    public func isQuiet(at now: Double) -> Bool { latest != nil && now - changedAt >= Self.quiet }

    /// Starts a step with the latest frame as the state before it.
    public mutating func arm() {
        (step, overflowed) = (latest.map { [$0] }, false)
    }

    public func settled(sent: Double, at now: Double) -> Settle? {
        guard let step else { return nil }
        let since = now - sent
        if overflowed || since >= Self.longest { return .cut }
        guard step.contains(where: { $0.time >= sent }) else { return since >= Self.unchanged ? .unchanged : nil }
        return since >= Self.shortest && now - changedAt >= Self.quiet ? .settled : nil
    }

    /// The step's frame before its send, and its frames from the send on.
    public mutating func take(sent: Double) -> (before: Picture, frames: [Picture])? {
        defer { step = nil }
        guard let step, let first = step.first else { return nil }
        let split = step.firstIndex { $0.time >= sent } ?? step.count
        return (split > 0 ? step[split - 1] : first, Array(step[split...]))
    }
}
