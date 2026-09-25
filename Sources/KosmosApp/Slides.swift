import AppKit
import CKosmos
import KosmosCore
import KosmosSkyLight
import Synchronization
import os

private let slideLog = Logger(subsystem: "io.github.st-eez.kosmos", category: "slide")

/// The slide trial behind `KOSMOS_ANIMATE=slide` (docs/geometry.md). A window a relayout
/// moves joins a Space of the pool, shown in place at level 1, and keeps its ordinary Space.
/// Its final frame goes through the ordinary frame path once, and the Space's transform shows
/// it at the frame it showed at, eased to identity; then the window leaves the Space. A
/// window admitted after launch onto a shown workspace pops in the same way. One display link
/// on the main actor steps every slide, and reads off the main thread follow each write until
/// it lands (Onscreen).
@MainActor
final class Slides {
    /// `KOSMOS_ANIMATE=slide` in the environment, read once at launch.
    static let enabled = ProcessInfo.processInfo.environment["KOSMOS_ANIMATE"] == "slide"
    /// One level above the desktop Space's, 0, where a window alone in a shown Space is drawn
    /// with the Space's transform and alpha (kosmos-probe space-anim, branch spaceanim).
    static let level: Int32 = 1
    /// The Spaces created at launch. A relayout that moves more windows than the pool has free
    /// grows it to `limit`, and the windows past the free ones jump that time. Not measured:
    /// Steve's workspaces hold a few windows each.
    private static let initialPool = 8
    private var limit = 16
    /// How long a new window waits, transparent, for its write to land before it pops in
    /// where it is.
    private static let popWait = 0.25
    /// How long after its write a slide that is over holds its window at the target while the
    /// write has not landed, so the window does not show at its old frame and then jump again.
    /// Past it the slide ends where WindowServer has the window. The worker's calls time out
    /// after 1 s.
    private static let landingWait = 1.0

    private struct Entry {
        let space: UInt64
        let pop: Bool
        var target: CGRect
        /// Nil while a pop waits for its write to land.
        var slide: Slide?
        /// The write the landing reads follow, so the landing of an older one is left out.
        var ticket: Int
        /// When the newest write was queued and when it landed, on CACurrentMediaTime's clock.
        var sent: Double
        var landed: Double?
        /// The newest write did not land within `landingWait`.
        var gaveUp = false
        /// When the window last showed where the slide had it: the display frame it was
        /// stepped for.
        var shownAt: Double
        var frames = 0
    }

    private let hiding: Hiding
    private var entries: [WindowID: Entry] = [:]
    private let onscreen = Onscreen()
    private var free: [UInt64] = []
    /// Spaces created or being created.
    private var pool = 0
    private var tickets = 0
    private var link: CADisplayLink?
    /// The display link's callbacks since it started, and their time, for the log.
    private var callbacks = 0, callbackTime = 0.0, slowestCallback = 0.0

    init(hiding: Hiding) {
        self.hiding = hiding
        grow(Self.initialPool)
    }

    /// Takes the frame writes about to go to the workers, before they are queued, so each
    /// sliding window joins its Space before its app takes the frame. `sliding`: the windows
    /// whose writes slide (Controller.animated). `from`: where WindowServer has each of them
    /// that is not sliding yet. `popping`: a window just admitted. A window with no free
    /// Space, or while the guardian is not ready to recover it, jumps. A write that does not
    /// slide, as a drag's, ends the window's slide to another frame at once.
    func writing(_ writes: [WindowID: CGRect], sliding: Set<WindowID>, from: [WindowID: CGRect], popping: WindowID?) {
        var slid = 0, jumped = 0, popped = false
        for (id, target) in writes {
            if sliding.contains(id) {
                guard begin(id, to: target, from: from[id], pop: id == popping) else {
                    jumped += 1
                    continue
                }
                slid += 1
                popped = popped || id == popping
            } else if let entry = entries[id], entry.target != target {
                end(id, "by a write that does not slide")
            }
        }
        if slid + jumped > 0 {
            slideLog.info("relayout: \(slid) windows slide\(popped ? ", 1 of them popping" : "", privacy: .public), \(jumped) jump, \(self.free.count) Spaces free")
        }
    }

    /// Ends at once the slide of each window `shown` rejects: concealed, parked, closed, or on
    /// a workspace no longer shown.
    func keep(_ shown: (WindowID) -> Bool) {
        for id in Array(entries.keys) where !shown(id) { end(id, "as it left the screen") }
    }

    /// Ends every slide, for quit, so recovery finds the pool's Spaces empty.
    func endAll() {
        for id in Array(entries.keys) { end(id, "at quit") }
        stopLink()
    }

    /// Ends the window's slide: its Space goes back to identity and alpha 1, and the window
    /// leaves it and shows at its own frame. `why` says why a slide ended before it was over.
    func end(_ id: WindowID, _ why: String? = nil) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        onscreen.state.withLock { state in
            state.windows[id] = nil
            kosmos_space_set_transform(entry.space, .identity)
            if entry.pop { kosmos_space_set_alpha(entry.space, 1) }
            var ids = [id]
            kosmos_remove_windows(entry.space, &ids, 1)
        }
        free.append(entry.space)
        // script/bench-relayout.sh counts these lines.
        let landed = entry.landed.map { String(format: "landed %.1f ms after its write", ($0 - entry.sent) * 1000) } ?? "did not land"
        if let why {
            slideLog.info("\(id) slide ended \(why, privacy: .public) after \(entry.frames) frames, \(landed, privacy: .public)")
        } else {
            slideLog.info("\(id) \(entry.pop ? "popped" : "slid", privacy: .public) in \(entry.frames) frames, \(landed, privacy: .public)")
        }
    }

    /// Starts the window's slide to `target` from `from`, or from where a slide under way
    /// shows it now. A pop waiting for its write waits on for the new one. False when the
    /// window jumps.
    private func begin(_ id: WindowID, to target: CGRect, from: CGRect?, pop: Bool) -> Bool {
        let now = CACurrentMediaTime()
        tickets += 1
        let ticket = tickets
        if var entry = entries[id] {
            entry.slide = entry.slide?.retargeted(to: target, at: entry.shownAt)
            (entry.target, entry.ticket, entry.sent, entry.landed, entry.gaveUp) = (target, ticket, now, nil, false)
            entries[id] = entry
            let waiting = entry.slide == nil
            onscreen.state.withLock { state in
                guard var window = state.windows[id] else { return }
                if waiting {
                    window.shown = target.scaled(Slide.popScale)
                    kosmos_space_set_transform(window.space, Slide.transform(showing: window.shown, at: window.actual))
                }
                window.awaiting = Onscreen.Awaiting(target: target, before: window.actual, ticket: ticket, changedAt: now,
                                                    deadline: now + (waiting ? Self.popWait : Self.landingWait))
                state.windows[id] = window
            }
            follow()
            endLate(id, ticket)
            return true
        }
        guard let from, from != target, hiding.guardianReady else { return false }
        guard let space = free.popLast() else {
            grow(limit)
            return false
        }
        let shown = pop ? target.scaled(Slide.popScale) : from
        onscreen.state.withLock { state in
            // A pop's Space turns transparent before the window joins it, so the window shows
            // nothing until it pops in.
            if pop {
                kosmos_space_set_alpha(space, 0)
                kosmos_space_set_transform(space, Slide.transform(showing: shown, at: from))
            }
            var ids = [id]
            kosmos_add_windows(space, &ids, 1, false)
            state.windows[id] = Onscreen.Window(
                space: space, shown: shown, alpha: pop ? 0 : 1, actual: from,
                awaiting: Onscreen.Awaiting(target: target, before: from, ticket: ticket, changedAt: now,
                                            deadline: now + (pop ? Self.popWait : Self.landingWait)))
        }
        entries[id] = Entry(space: space, pop: pop, target: target, slide: pop ? nil : .move(from: from, to: target, at: now),
                            ticket: ticket, sent: now, shownAt: now)
        follow()
        startLink()
        endLate(id, ticket)
        return true
    }

    /// Ends the slide for write `ticket` once no slide can still run, should the display link
    /// stop stepping it, as it might when its display goes: a move holds its window for
    /// `landingWait` at most, and a pop starts within `popWait` and lasts `popDuration`.
    private func endLate(_ id: WindowID, _ ticket: Int) {
        let late = Self.landingWait + Self.popWait + Slide.popDuration
        DispatchQueue.main.asyncAfter(deadline: .now() + late) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.entries[id]?.ticket == ticket else { return }
                self.end(id, "late, past every slide's end")
            }
        }
    }

    /// A write landed, or its wait ran out: a move ends at the frame WindowServer has, and a
    /// pop starts there.
    private func landed(_ landings: [Onscreen.Landing]) {
        for landing in landings {
            guard var entry = entries[landing.id], entry.ticket == landing.ticket else { continue }
            if landing.timedOut {
                entry.gaveUp = true
            } else {
                entry.landed = landing.at
                entry.slide?.to = landing.frame
            }
            if entry.slide == nil {
                let now = CACurrentMediaTime()
                entry.slide = .pop(to: landing.frame, at: now)
                entry.shownAt = now
            }
            entries[landing.id] = entry
        }
    }

    /// One display frame: each slide shows its window where it has it at the time the frame
    /// shows, and a slide that is over ends, or holds its window at the target until its
    /// write lands.
    private func frame(_ link: CADisplayLink) {
        let began = CACurrentMediaTime()
        let at = link.targetTimestamp
        var over: [WindowID] = [], steps: [(id: WindowID, shown: CGRect, alpha: Float)] = []
        for (id, entry) in entries {
            guard let slide = entry.slide else { continue }
            if slide.isOver(at: at) {
                if entry.landed == nil, !entry.gaveUp {
                    steps.append((id, slide.to, 1))
                    entries[id]!.shownAt = at
                } else {
                    over.append(id)
                }
                continue
            }
            steps.append((id, slide.shown(at: at), Float(slide.alpha(at: at))))
            entries[id]!.shownAt = at
            entries[id]!.frames += 1
        }
        let due = steps
        onscreen.state.withLock { state in
            for step in due {
                // A window held at its target needs no new transform: the landing reads send
                // one at each new frame.
                guard var window = state.windows[step.id], window.shown != step.shown || window.alpha != step.alpha else { continue }
                window.shown = step.shown
                kosmos_space_set_transform(window.space, Slide.transform(showing: step.shown, at: window.actual))
                if step.alpha != window.alpha {
                    kosmos_space_set_alpha(window.space, step.alpha)
                    window.alpha = step.alpha
                }
                state.windows[step.id] = window
            }
        }
        for id in over { end(id) }
        let spent = CACurrentMediaTime() - began
        callbacks += 1
        callbackTime += spent
        slowestCallback = max(slowestCallback, spent)
        if entries.isEmpty { stopLink() }
    }

    /// Steps the slides at the frames of the fastest display, so no display misses a step.
    private func startLink() {
        guard link == nil else { return }
        guard let screen = NSScreen.screens.max(by: { $0.maximumFramesPerSecond < $1.maximumFramesPerSecond }) else {
            return endAll()
        }
        // The link keeps its target.
        let link = screen.displayLink(target: LinkTarget { [weak self] in self?.frame($0) }, selector: #selector(LinkTarget.frame))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
        (callbacks, callbackTime, slowestCallback) = (0, 0, 0)
    }

    private func stopLink() {
        guard let link else { return }
        link.invalidate()
        self.link = nil
        // script/bench-relayout.sh counts this line.
        slideLog.info("""
            slide frames: \(self.callbacks) callbacks, \(self.callbackTime * 1000, format: .fixed(precision: 2)) ms in them, \
            \(self.slowestCallback * 1000, format: .fixed(precision: 2)) ms at most
            """)
    }

    /// Starts the landing reads unless they run.
    private func follow() {
        let onscreen = self.onscreen
        let idle = onscreen.state.withLock { state in
            defer { state.following = true }
            return !state.following
        }
        guard idle else { return }
        onscreen.queue.async {
            onscreen.follow { [weak self] landings in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.landed(landings) } }
            }
        }
    }

    /// Creates up to `count` more Spaces, within the limit. When the record cannot take them
    /// or they cannot be created, the pool stays as it is.
    private func grow(_ count: Int) {
        let count = min(count, limit - pool)
        guard count > 0 else { return }
        pool += count
        hiding.createAnimationSpaces(count, level: Self.level) { [weak self] spaces in
            guard let self else { return }
            free += spaces
            if spaces.count < count {
                pool -= count - spaces.count
                limit = pool
            }
            slideLog.info("\(spaces.count) of \(count) animation Spaces created, \(self.pool) in the pool")
        }
    }
}

/// What the display link and the landing reads share: where each sliding window shows and
/// where WindowServer has it. Both send a window's transform under the lock, so the last one
/// sent is for the newest frame.
private final class Onscreen: Sendable {
    struct Window: Sendable {
        let space: UInt64
        var shown: CGRect
        var alpha: Float
        /// The window's frame as WindowServer last had it.
        var actual: CGRect
        var awaiting: Awaiting?
    }

    /// A write that has not landed yet.
    struct Awaiting: Sendable {
        let target: CGRect
        /// The window's frame when the write was queued.
        let before: CGRect
        let ticket: Int
        /// When the window's frame last changed, or the write was queued.
        var changedAt: Double
        let deadline: Double
    }

    struct Landing: Sendable {
        let id: UInt32
        let frame: CGRect
        let ticket: Int
        let at: Double
        /// The deadline came first.
        let timedOut: Bool
    }

    struct State: Sendable {
        var windows: [UInt32: Window] = [:]
        var following = false
    }

    let state = Mutex(State())
    let queue = DispatchQueue(label: "kosmos.slide", qos: .userInteractive)
    /// How long a new frame other than the target must stay before it counts as landed: at
    /// the target's origin, as an app that rounds or refuses its size leaves it, and
    /// elsewhere, as an app that places the window itself does. A size, position and size
    /// written in turn can land in more than one commit, and a write a newer one replaces
    /// can land first, at another origin. Not measured.
    private static let settle = 0.025, settleElsewhere = 0.1

    /// Reads the rows of the windows whose writes have not landed every 0.1 ms, as Hiding
    /// reads a batch's Spaces, until none is left. At each new frame WindowServer gives a
    /// window, its transform keeps it where it shows. A write lands with the app's next
    /// commit, 9 ms after it at the median and 15 ms at most in `kosmos-probe space-anim demo`
    /// (branch spaceanim), where a transform lands within about 0.4 ms. A window has landed
    /// once it has the target, or has kept a new frame for `settle`, or at its deadline,
    /// which it reports as timed out. `landed` gets each with that frame.
    func follow(_ landed: @Sendable ([Landing]) -> Void) {
        while true {
            let ids = state.withLock { state in
                let ids = state.windows.compactMap { $0.value.awaiting == nil ? nil : $0.key }
                if ids.isEmpty { state.following = false }
                return ids
            }
            guard !ids.isEmpty else { return }
            let rows = Dictionary(SkyLight.rows(ids).map { ($0.id, $0.frame) }) { first, _ in first }
            let now = CACurrentMediaTime()
            let landings = state.withLock { state in
                var landings: [Landing] = []
                for id in ids {
                    guard var window = state.windows[id], var awaiting = window.awaiting else { continue }
                    // Closed: the Controller ends its slide.
                    guard let frame = rows[id] else {
                        state.windows[id]!.awaiting = nil
                        continue
                    }
                    if frame != window.actual {
                        window.actual = frame
                        awaiting.changedAt = now
                        kosmos_space_set_transform(window.space, Slide.transform(showing: window.shown, at: frame))
                    }
                    let settled = frame != awaiting.before
                        && now - awaiting.changedAt >= (frame.origin == awaiting.target.origin ? Self.settle : Self.settleElsewhere)
                    if frame == awaiting.target || settled || now >= awaiting.deadline {
                        window.awaiting = nil
                        landings.append(Landing(id: id, frame: frame, ticket: awaiting.ticket, at: now,
                                                timedOut: frame != awaiting.target && !settled))
                    } else {
                        window.awaiting = awaiting
                    }
                    state.windows[id] = window
                }
                return landings
            }
            if !landings.isEmpty { landed(landings) }
            usleep(100)
        }
    }
}

/// The display link's target, since CADisplayLink calls an Objective-C selector. The link
/// runs on the main run loop.
@MainActor
private final class LinkTarget: NSObject {
    private let step: @MainActor (CADisplayLink) -> Void

    init(_ step: @escaping @MainActor (CADisplayLink) -> Void) { self.step = step }

    @objc func frame(_ link: CADisplayLink) { step(link) }
}
