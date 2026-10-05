import CoreGraphics

/// The edge of its display that a peek shows a window past (docs/hiding.md).
public enum PeekEdge: String, Equatable, Sendable {
    case right, left

    /// A frame of `size` with one column of points on `display`, past its right edge, else its
    /// left, with its top 40 points down; nil when another display lies past both, as a frame
    /// over another display would show the window there. AppKit keeps a window's top edge on
    /// its display, so TextEdit and Chrome for Testing refused a bottom corner in kosmos-probe
    /// peek on 2026-10-05 and took an edge.
    public static func frame(_ size: CGSize, on display: CGRect, besides others: [CGRect]) -> (edge: PeekEdge, frame: CGRect)? {
        let top = display.minY + max(0, min(40, display.height - size.height))
        let candidates: [(PeekEdge, CGFloat)] = [(.right, display.maxX - 1), (.left, display.minX - size.width + 1)]
        for (edge, x) in candidates {
            let frame = CGRect(origin: CGPoint(x: x, y: top), size: size)
            if !others.contains(where: { $0.intersects(frame) }) { return (edge, frame) }
        }
        return nil
    }
}

/// `kosmos peek`: a concealed window moved past its display's edge, then taken out of the
/// holding Space while a command captures it, then concealed again and moved back
/// (docs/hiding.md). One peek runs at a time, in the order asked. The controller reports each
/// step's event and carries out the actions it gets back, then calls `next`, so a peek's end
/// is carried out before the next peek reads the window's frame.
public struct Peeks: Sendable {
    /// The edge write's row shows within this, or the peek gives up: the Accessibility timeout,
    /// after which a frame write counts as landed (docs/hiding.md).
    public static let moveBound = AXBackoff.timeout
    /// Kosmos cannot see another app draw, so the command waits this long after the window
    /// leaves the holding Space. kosmos-probe peek's captures on 2026-10-05 were current 74 to
    /// 118 ms after the peek at the median and 156 ms at most in any variant (docs/hiding.md).
    /// Ceiling: an app slower to draw, as Discord black for about a second, gives a stale or black
    /// capture. Upgrade: Kosmos captures the window until a capture is drawn and stops changing,
    /// as the probe judges Electron apps, at about 80 ms a capture.
    public static let settle: Duration = .milliseconds(160)
    /// A command still running this long after it started loses its peek: about 20 times
    /// CuaDriver's get_window_state, 458 ms on 2026-10-05 (docs/hiding.md). Ceiling: a slower
    /// command's captures after it fail. Upgrade: a timeout the CLI passes.
    public static let timeout: Duration = .seconds(10)

    public enum Phase: Equatable, Sendable {
        /// Behind another peek, or behind a write of Kosmos's to the window still landing.
        case waiting
        /// The edge frame written, the window still concealed.
        case moving
        /// On its way out of the holding Space.
        case revealing
        /// Out, while its app draws.
        case settling
        /// The command runs.
        case running
    }

    public enum Outcome: Equatable, Sendable {
        /// The CLI reported the command's end.
        case finished
        /// The CLI closed the connection first.
        case clientGone
        case timedOut
        /// Kosmos no longer conceals it, or a batch not done reveals it.
        case notConcealed
        /// Another display lies past each edge of its display.
        case noEdge
        /// It did not take the edge frame: where its app put it, nil when no row showed it in time.
        case refused(CGRect?)
        /// It did not leave the holding Space.
        case notRevealed
        /// A switch showed its workspace.
        case shown
        /// A resync after a failed batch concealed it again.
        case resynced
        /// It closed, or left the screen as a deselected tab.
        case closed
        case locked
        case screensSlept
        case displaysChanged
        case quit
    }

    public struct Peek: Equatable, Sendable {
        public let number: Int
        public let window: WindowID
        public internal(set) var phase = Phase.waiting
        /// The frame it goes back to.
        public internal(set) var rest = CGRect.null
        public internal(set) var edge = CGRect.null
    }

    /// What `prepare` finds when a peek's turn comes.
    public enum Preparation: Equatable, Sendable {
        case ready(rest: CGRect, edge: CGRect)
        /// A write of Kosmos's to the window is still landing, until `until` at most: the edge's
        /// row could not be told from a row before it.
        case later(until: ContinuousClock.Instant)
        case none(Outcome)
    }

    public enum Action: Equatable, Sendable {
        /// Call `next` again at the time, or at a landing before it.
        case retry(at: ContinuousClock.Instant)
        /// Write the edge frame; `landed`, `answered` or `moveEnded` follows.
        case move(Peek)
        /// Take it out of the holding Space; `revealed` follows.
        case reveal(Peek)
        /// Wait `settle`; `settled` follows.
        case settle(Peek)
        /// Tell the CLI to run the command, and start `timeout`.
        case run(Peek)
        /// Put it back in the holding Space when `conceal`, then write `rest` when there is one.
        case end(Peek, Outcome, conceal: Bool, rest: CGRect?)
    }

    /// The first is under way unless it waits.
    private var queue: [Peek] = []
    private var last = 0

    public init() {}

    /// The peek under way.
    public var active: Peek? { queue.first.flatMap { $0.phase == .waiting ? nil : $0 } }

    public var isEmpty: Bool { queue.isEmpty }

    /// The windows of the peeks waiting or under way.
    public var windows: [WindowID] { queue.map(\.window) }

    /// A peek of `window`, which waits behind those asked before it until `next` starts it.
    public mutating func request(_ window: WindowID) -> Int {
        last += 1
        queue.append(Peek(number: last, window: window))
        return last
    }

    /// With none under way, starts the first peek waiting. One that `prepare` finds nothing to
    /// do for ends, and the next is tried.
    public mutating func next(prepare: (WindowID) -> Preparation) -> [Action] {
        var actions: [Action] = []
        while var peek = queue.first, peek.phase == .waiting {
            switch prepare(peek.window) {
            case .ready(let rest, let edge):
                (peek.phase, peek.rest, peek.edge) = (.moving, rest, edge)
                queue[0] = peek
                return actions + [.move(peek)]
            case .later(let until):
                return actions + [.retry(at: until)]
            case .none(let outcome):
                actions.append(end(queue.removeFirst(), outcome))
            }
        }
        return actions
    }

    /// A row of the window from WindowServer.
    public mutating func landed(_ number: Int, frame: CGRect) -> [Action] {
        guard var peek = current(number, in: .moving), Self.matches(frame, peek.edge) else { return [] }
        peek.phase = .revealing
        queue[0] = peek
        return [.reveal(peek)]
    }

    /// The frame its app read back after the edge write: anywhere else, AppKit kept it on the
    /// display.
    public mutating func answered(_ number: Int, readBack: CGRect) -> [Action] {
        guard let peek = current(number, in: .moving), !Self.matches(readBack, peek.edge) else { return [] }
        return [end(queue.removeFirst(), .refused(readBack))]
    }

    /// `moveBound` passed since the edge write.
    public mutating func moveEnded(_ number: Int) -> [Action] {
        guard current(number, in: .moving) != nil else { return [] }
        return [end(queue.removeFirst(), .refused(nil))]
    }

    public mutating func revealed(_ number: Int, _ out: Bool) -> [Action] {
        guard var peek = current(number, in: .revealing) else { return [] }
        guard out else { return [end(queue.removeFirst(), .notRevealed)] }
        peek.phase = .settling
        queue[0] = peek
        return [.settle(peek)]
    }

    public mutating func settled(_ number: Int) -> [Action] {
        guard var peek = current(number, in: .settling) else { return [] }
        peek.phase = .running
        queue[0] = peek
        return [.run(peek)]
    }

    /// The CLI's report, its close or the timeout, in any phase. Nothing for a peek already
    /// ended.
    public mutating func ended(_ number: Int, _ outcome: Outcome) -> [Action] {
        guard let index = queue.firstIndex(where: { $0.number == number }) else { return [] }
        return [end(queue.remove(at: index), outcome)]
    }

    /// Ends each peek of `window`, waiting or under way, or every peek with nil.
    public mutating func giveWay(_ window: WindowID?, _ outcome: Outcome) -> [Action] {
        let gone = queue.filter { window == nil || $0.window == window }
        queue.removeAll { window == nil || $0.window == window }
        return gone.map { end($0, outcome) }
    }

    /// Within a point, as kosmos-probe peek checked the move.
    static func matches(_ frame: CGRect, _ edge: CGRect) -> Bool {
        abs(frame.minX - edge.minX) < 1 && abs(frame.minY - edge.minY) < 1
    }

    private func current(_ number: Int, in phase: Phase) -> Peek? {
        guard let peek = queue.first, peek.number == number, peek.phase == phase else { return nil }
        return peek
    }

    /// A window that closed left every Space, so it is neither concealed nor moved again.
    private func end(_ peek: Peek, _ outcome: Outcome) -> Action {
        if outcome == .closed { return .end(peek, outcome, conceal: false, rest: nil) }
        return switch peek.phase {
        case .waiting: .end(peek, outcome, conceal: false, rest: nil)
        case .moving: .end(peek, outcome, conceal: false, rest: peek.rest)
        case .revealing, .settling, .running: .end(peek, outcome, conceal: true, rest: peek.rest)
        }
    }
}
