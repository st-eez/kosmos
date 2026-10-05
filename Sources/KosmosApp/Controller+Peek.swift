import AppKit
import KosmosCore
import KosmosIPC
import os

/// The peeks asked for and what each CLI waits on (docs/hiding.md).
struct PeekBook {
    var peeks = Peeks()
    /// Each CLI waiting for its peek: nil runs the command under it, a response without it.
    var waiting: [Int: CheckedContinuation<Response?, Never>] = [:]
    var records: [Int: PeekRecord] = [:]
    /// Why Kosmos ended a peek before its CLI reported the command's end.
    var endedEarly: [Int: Peeks.Outcome] = [:]
    /// Writes back that a lock held, sent at the unlock.
    var owed: [WindowID: CGRect] = [:]
    /// When `next` runs again for a peek waiting for a write to land.
    var retryAt: ContinuousClock.Instant?
    /// A target written for the peek's window while it was under way, which its end writes in
    /// place of the frame it had.
    var later: [WindowID: CGRect] = [:]
}

/// When each step of a peek came, for its log line.
struct PeekRecord {
    let asked: ContinuousClock.Instant
    var moved: ContinuousClock.Instant?
    var landed: ContinuousClock.Instant?
    var out: ContinuousClock.Instant?
    var ran: ContinuousClock.Instant?
    var place = ""
    var status: String?
}

extension Controller {
    /// `kosmos peek`: answers at once, holding nothing, unless Kosmos conceals the window, and
    /// else once the window shows past its display's edge, holding the connection until the
    /// CLI reports its command's end (docs/hiding.md, docs/ipc.md).
    func peek(_ window: WindowID) async -> Reply {
        guard hiding.isConcealed(window) else { return Reply(Response()) }
        var asked = 0
        let answer: Response? = await withCheckedContinuation { continuation in
            let number = peeking.peeks.request(window)
            asked = number
            peeking.waiting[number] = continuation
            peeking.records[number] = PeekRecord(asked: .now)
            stepPeeks { _ in [] }
        }
        if let answer { return Reply(answer) }
        let number = asked
        return Reply(Response()) { [weak self] args in self?.peekReported(number, args) ?? Response() }
    }

    /// Ends each peek of `window`, or every peek with nil, in the way its phase can be undone
    /// (Peeks.giveWay).
    func peekGiveWay(_ window: WindowID?, _ outcome: Peeks.Outcome) {
        guard !peeking.peeks.isEmpty else { return }
        stepPeeks { $0.giveWay(window, outcome) }
    }

    /// Before a plan's batches, which a peek's end goes ahead of (docs/hiding.md).
    func peeksGiveWay(show: [WindowID], hide: [WindowID]) {
        for window in peeking.peeks.windows {
            if show.contains(window) {
                peekGiveWay(window, .shown)
            } else if hide.contains(window) {
                peekGiveWay(window, .resynced)
            }
        }
    }

    /// A row of the window, from its change event or the one last read, after the ledger saw
    /// it: the edge write landing, or a write the first peek waits for.
    func peekSaw(_ window: WindowID, frame: CGRect) {
        guard !peeking.peeks.isEmpty else { return }
        guard let peek = peeking.peeks.active else {
            if peeking.peeks.windows.first == window { stepPeeks { _ in [] } }
            return
        }
        guard peek.window == window, peek.phase == .moving else { return }
        stepPeeks { $0.landed(peek.number, frame: frame) }
    }

    /// WindowServer can take the frame before the read back comes (docs/hiding.md).
    func peekAnswered(_ window: WindowID, target: CGRect, readBack: CGRect) {
        guard !peeking.peeks.isEmpty else { return }
        if let peek = peeking.peeks.active, peek.window == window, peek.phase == .moving, target == peek.edge {
            stepPeeks { $0.answered(peek.number, readBack: readBack) }
        }
        if let row = inventory.windows[window] { peekSaw(window, frame: row.frame) }
    }

    /// The targets less the window of the peek under way, whose target waits for its end.
    func holdingPeeked(_ targets: [WindowID: CGRect]) -> [WindowID: CGRect] {
        guard let peek = peeking.peeks.active, let target = targets[peek.window] else { return targets }
        peeking.later[peek.window] = target
        var others = targets
        others[peek.window] = nil
        return others
    }

    /// At the unlock, before the resync's plan.
    func writeOwedPeekFrames() {
        guard !peeking.owed.isEmpty else { return }
        let owed = peeking.owed.filter { hiding.isConcealed($0.key) }
        peeking.owed = [:]
        writeFrames(owed)
    }

    /// A peek's end still under way is no obstacle: the next peek's edge write joins its write
    /// back, which waits for it, and its Space change queues behind it. A write already sent
    /// is: until a row shows it, a row at the edge could be one from before it.
    private func preparePeek(_ window: WindowID) -> Peeks.Preparation {
        if sessionLocked { return .none(.locked) }
        guard managing, hiding.canConceal, hiding.isConcealed(window), !order.reveals(window),
              let name = session.workspace(of: window), !session.isShown(name), !session.isParked(window),
              owner[window].flatMap(inventory.worker)?.answers == true, let rest = knownFrame(window)
        else { return .none(.notConcealed) }
        let now = ContinuousClock.now
        if ledger.isLanding(window, at: now), let until = ledger.landingEnds(window) { return .later(until: until) }
        let monitor = session.monitor(of: name)
        let others = session.monitors.filter { $0.id != monitor.id }.map(\.frame)
        guard let found = PeekEdge.frame(rest.size, on: monitor.frame, besides: others) else { return .none(.noEdge) }
        return .ready(rest: rest, edge: found.frame)
    }

    /// The step's actions run before the next peek is prepared, which reads the frame an end
    /// writes back. `preparePeek` reads the model only, as `peeking` is in use while it runs.
    private func stepPeeks(_ step: (inout Peeks) -> [Peeks.Action]) {
        perform(step(&peeking.peeks))
        perform(peeking.peeks.next { self.preparePeek($0) })
    }

    private func perform(_ actions: [Peeks.Action]) {
        for action in actions {
            switch action {
            case .retry(let at):
                guard peeking.retryAt.map({ at < $0 }) ?? true else { continue }
                peeking.retryAt = at
                after(at - .now) { controller in
                    if controller.peeking.retryAt == at { controller.peeking.retryAt = nil }
                    controller.stepPeeks { _ in [] }
                }
            case .move(let peek):
                let monitor = session.workspace(of: peek.window).map { session.monitor(of: $0) }
                let edge = monitor.map { peek.edge.maxX > $0.frame.maxX ? "right" : "left" } ?? "?"
                peeking.records[peek.number]?.moved = .now
                peeking.records[peek.number]?.place = "past the \(edge) edge of display \(monitor?.id ?? 0)"
                writeFrames([peek.window: peek.edge], ownPeek: true)
                after(Peeks.moveBound) { $0.stepPeeks { $0.moveEnded(peek.number) } }
            case .reveal(let peek):
                peeking.records[peek.number]?.landed = .now
                let display = session.workspace(of: peek.window).map { session.monitor(of: $0).id }
                hiding.peek(peek.window, on: display) { [weak self] out in
                    self?.peeking.records[peek.number]?.out = .now
                    self?.stepPeeks { $0.revealed(peek.number, out) }
                }
            case .settle(let peek):
                after(Peeks.settle) { $0.stepPeeks { $0.settled(peek.number) } }
            case .run(let peek):
                peeking.records[peek.number]?.ran = .now
                peeking.waiting.removeValue(forKey: peek.number)?.resume(returning: nil)
                after(Peeks.timeout) { $0.stepPeeks { $0.ended(peek.number, .timedOut) } }
            case .end(let peek, let outcome, let conceal, let rest):
                endPeek(peek, outcome, conceal: conceal, rest: rest)
            }
        }
    }

    /// The window goes back into the holding Space in a batch of its own, sent ahead of the
    /// batches waiting, and its write back waits for that batch, as does a switch that shows it
    /// (BatchOrder.addSent). While locked the batch still goes, as a lock or display change with
    /// the window out made the next batch fail on 2026-10-05, and the write waits for the unlock.
    private func endPeek(_ peek: Peeks.Peek, _ outcome: Peeks.Outcome, conceal: Bool, rest: CGRect?) {
        if let waiting = peeking.waiting.removeValue(forKey: peek.number) {
            // The command runs without the peek.
            let quiet = outcome == .notConcealed || outcome == .shown
            waiting.resume(returning: quiet ? Response() : Response(stderr: "kosmos: no peek: \(Self.describe(outcome))"))
        } else if outcome != .finished && outcome != .clientGone {
            peeking.endedEarly[peek.number] = outcome
        }
        let ended = ContinuousClock.now
        if conceal {
            let batch = order.addSent(hide: [peek.window])
            hiding.apply(show: [], on: [:], hide: [peek.window], stripping: []) { [weak self] result, _ in
                guard let self else { return }
                sendWrites(order.done(batch.number))
                sendReadyBatches()
                if case .failed = result {
                    controllerLog.error("the conceal after a peek of \(peek.window) failed; recovery ran")
                    needsResync = true
                }
                logPeek(peek, outcome, ended: ended, concealed: result)
            }
        }
        let later = peeking.later.removeValue(forKey: peek.window)
        if let rest = rest.map({ later ?? $0 }) {
            if sessionLocked { peeking.owed[peek.window] = rest } else { writeFrames([peek.window: rest]) }
        }
        if !conceal { logPeek(peek, outcome, ended: ended, concealed: nil) }
    }

    /// The CLI's report of the command's end, or nil at its close.
    private func peekReported(_ number: Int, _ args: [String]?) -> Response {
        if let args, args.count == 2, args[0] == "ended" { peeking.records[number]?.status = args[1] }
        stepPeeks { $0.ended(number, args == nil ? .clientGone : .finished) }
        guard let early = peeking.endedEarly.removeValue(forKey: number) else { return Response() }
        return Response(stderr: "kosmos: the peek ended before the command did: \(Self.describe(early))")
    }

    private func logPeek(_ peek: Peeks.Peek, _ outcome: Peeks.Outcome, ended: ContinuousClock.Instant, concealed: Hiding.Outcome?) {
        guard let record = peeking.records.removeValue(forKey: peek.number) else { return }
        func ms(_ from: ContinuousClock.Instant?, _ to: ContinuousClock.Instant?) -> String? {
            guard let from, let to else { return nil }
            return String(format: "%.3f ms", (to - from).milliseconds)
        }
        let steps = [("waited", ms(record.asked, record.moved ?? ended)), ("edge", ms(record.moved, record.landed)),
                     ("out", ms(record.landed, record.out)), ("settled", ms(record.out, record.ran)),
                     ("command", ms(record.ran, ended))]
            .compactMap { name, time in time.map { "\(name) \($0)" } }
        let back = switch concealed {
        case nil: ""
        case .failed?: "; the conceal failed"
        case .revealedOnly?: "; not concealed again, as no guardian is ready"
        case .confirmed?: String(format: "; concealed again in %.3f ms", (ContinuousClock.now - ended).milliseconds)
        }
        controllerLog.notice("""
            peek of \(peek.window) (\(self.appName(peek.window) ?? "?", privacy: .public))\
            \(record.place.isEmpty ? "" : " " + record.place, privacy: .public): \(Self.describe(outcome), privacy: .public)\
            \(record.status.map { ", exit \($0)" } ?? "", privacy: .public); \
            \(String(format: "%.3f", (ended - record.asked).milliseconds), privacy: .public) ms in all: \
            \(steps.joined(separator: ", "), privacy: .public)\(back, privacy: .public)
            """)
    }

    static func describe(_ outcome: Peeks.Outcome) -> String {
        switch outcome {
        case .finished: "the command ended"
        case .clientGone: "the CLI closed its connection first"
        case .timedOut: "the command ran past \(Peeks.timeout)"
        case .notConcealed: "Kosmos does not conceal the window"
        case .noEdge: "another display lies past each side of the window's display"
        case .refused(let frame?): "the window took \(Int(frame.minX)), \(Int(frame.minY)) in place of its frame past the display's edge"
        case .refused(nil): "no row showed the window past the display's edge within \(Peeks.moveBound)"
        case .notRevealed: "the window did not leave the holding Space"
        case .shown: "a switch showed its workspace"
        case .resynced: "a resync concealed it again"
        case .closed: "the window closed"
        case .locked: "the session locked"
        case .screensSlept: "the displays slept"
        case .displaysChanged: "the displays changed"
        case .quit: "Kosmos quit"
        }
    }
}
