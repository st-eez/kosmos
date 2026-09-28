import AppKit
import CKosmos
import KosmosCore
import KosmosSkyLight
import Synchronization
import os

private let slideLog = Logger(subsystem: "io.github.st-eez.kosmos", category: "slide")

/// Slides windows to the frames a relayout writes, and pops a new window in, through a pool
/// of Spaces whose transforms show each window where it showed. The display links call back
/// on a thread of their own and each display frame is stepped off the main actor, so main
/// actor work delays none (docs/geometry.md). The exception is a window that begins to slide
/// with its ring showing, whose first display frame waits for its relayout's border update
/// to hand the slide that ring (docs/borders.md).
@MainActor
final class Slides {
    /// `from` is where WindowServer has the window, nil while a write of Kosmos's still moves it.
    /// `ringed`: its border shows, so it takes no display frame until the border update hands
    /// the slide that ring or puts it back (docs/borders.md).
    struct Motion {
        var from: CGRect?
        var display: DisplayID
        var pop = false
        var ringed = false
    }

    /// One above the desktop Space's, where a shown Space draws its window with its transform
    /// and alpha (kosmos-probe space-anim).
    private static let level: Int32 = 1
    private static let poolSize = 8

    private let hiding: Hiding
    var onChange: (@MainActor () -> Void)?
    private let onscreen = Onscreen()
    private var free: [SpaceID] = []
    private let poolChecks = DispatchQueue(label: "kosmos.slide.pool", qos: .utility)
    private var links: [DisplayID: CADisplayLink] = [:]
    /// The display links' run loop, which nothing else runs on. It adds and invalidates them,
    /// in order.
    private let linkThread = RunLoopExecutor(name: "kosmos.slide.links")

    init(hiding: Hiding) {
        self.hiding = hiding
        hiding.createAnimationSpaces(Self.poolSize, level: Self.level) { [weak self] spaces in
            self?.free += spaces
            slideLog.info("\(spaces.count) of \(Self.poolSize) animation Spaces created")
        }
    }

    /// Called before the writes are queued, so a window joins its Space before its app takes
    /// the frame.
    func writing(_ targets: [WindowID: CGRect], sliding: [WindowID: Motion]) {
        let now = CACurrentMediaTime()
        var ended: [(WindowID, SlidingWindow)] = []
        var slid = 0, jumped = 0, took = 0, held = false
        let known = onscreen.state.withLock { state in
            var known: Set<WindowID> = []
            for (id, target) in targets {
                guard var window = state.windows[id] else { continue }
                known.insert(id)
                if window.wrote(target, sliding: sliding[id] != nil, at: now) {
                    state.windows[id] = window
                    took += 1
                    if sliding[id] != nil { slid += 1 }
                } else if let window = Onscreen.remove(id, from: &state) {
                    ended.append((id, window))
                }
            }
            return known
        }
        for (id, window) in ended { finished(id, window, "by a write that does not slide") }
        var popped = false
        for (id, target) in targets where !known.contains(id) {
            guard let motion = sliding[id], motion.from != target || motion.pop else { continue }
            guard let from = motion.from, begin(id, from: from, to: target, motion, at: now) else {
                jumped += 1
                continue
            }
            (slid, took, popped, held) = (slid + 1, took + 1, popped || motion.pop, held || motion.ringed)
        }
        if !ended.isEmpty { stopIdleLinks() }
        if took > 0 { onscreen.follow() }
        // The turn's border update lets the held windows go; this does, should it not run.
        if held { onMain { [onscreen] in onscreen.release() } }
        if slid + jumped > 0 {
            slideLog.info("relayout: \(slid) windows slide\(popped ? ", 1 of them popping" : "", privacy: .public), \(jumped) jump, \(self.free.count) Spaces free")
        }
    }

    func confirmed(_ id: WindowID, target: CGRect, readBack: CGRect) {
        let now = CACurrentMediaTime()
        onscreen.state.withLock { $0.windows[id]?.confirmed(target: target, readBack: readBack, at: now) }
    }

    /// Ends the slides of windows `visible` rejects or on a display of `fullscreen`, before a
    /// batch conceals them.
    func keep(_ visible: (WindowID) -> Bool, fullscreen: Set<DisplayID>) {
        let displays = onscreen.state.withLock { $0.windows.mapValues(\.display) }
        for (id, display) in displays where !visible(id) || fullscreen.contains(display) { end(id, "as it left the screen") }
    }

    /// Where the window shows as of its link's last display frame, at what alpha, and the path
    /// that holds every frame its slide can still show it at; nil when it is not sliding.
    func shown(_ id: WindowID) -> (frame: CGRect, alpha: Double, path: CGRect)? {
        onscreen.state.withLock { state in state.windows[id].map { ($0.shown, $0.alpha, $0.path) } }
    }

    func isSliding(_ id: WindowID) -> Bool {
        onscreen.state.withLock { $0.windows[id] != nil }
    }

    /// A change to the newest write's frame leaves the slide: WindowServer can take it after
    /// the worker read it back, while the user holds the button (docs/geometry.md).
    func changedInPress(_ id: WindowID, to frame: CGRect) {
        guard onscreen.state.withLock({ $0.windows[id].map { !$0.isWrite(frame) } }) == true else { return }
        end(id, "as the user moved it")
    }

    /// The border windows whose rings each sliding window's display frames move, in place of
    /// those handed before (docs/borders.md).
    func hand(_ rings: [WindowID: HandedRing]) {
        onscreen.hand(rings)
    }

    /// The windows begun with their ring showing that take no display frame yet.
    var held: Set<WindowID> {
        onscreen.state.withLock { $0.held }
    }

    func end(_ id: WindowID, _ why: String) {
        guard let window = onscreen.state.withLock({ Onscreen.remove(id, from: &$0) }) else { return }
        finished(id, window, why)
        stopIdleLinks()
    }

    /// Stops every display link too: one whose display went stops firing (docs/geometry.md).
    func endAll(_ why: String) {
        let all = onscreen.state.withLock { state in
            Array(state.windows.keys).compactMap { id in Onscreen.remove(id, from: &state).map { (id, $0) } }
        }
        for (id, window) in all { finished(id, window, why) }
        for display in Array(links.keys) { stopLink(display) }
    }

    /// False when the window jumps. A pop's Space turns transparent before the window joins it.
    private func begin(_ id: WindowID, from: CGRect, to target: CGRect, _ motion: Motion, at now: Double) -> Bool {
        guard hiding.canConceal else { return false }
        guard let space = free.popLast() else {
            slideLog.notice("\(id) jumps: no animation Space is free")
            return false
        }
        guard startLink(on: motion.display) else {
            free.append(space)
            return false
        }
        let window = SlidingWindow(space: space, display: motion.display, from: from, to: target, pop: motion.pop, at: now)
        onscreen.state.withLock { state in
            if motion.pop {
                kosmos_space_set_alpha(space, 0)
                window.show()
            }
            var ids = [id]
            kosmos_add_windows(space, &ids, 1, false)
            state.windows[id] = window
            if motion.ringed { state.held.insert(id) }
        }
        return true
    }

    /// `why` is nil for a slide that ran to its end.
    private func finished(_ id: WindowID, _ window: SlidingWindow, _ why: String? = nil) {
        release(window.space, of: id)
        onChange?()
        // script/bench-relayout.sh counts these lines.
        let landed = window.landed.map { String(format: "landed %.1f ms after its write", ($0 - window.sent) * 1000) } ?? "did not land"
        if let why {
            slideLog.info("\(id) slide ended \(why, privacy: .public) after \(window.frames) frames, \(landed, privacy: .public)")
        } else {
            slideLog.info("\(id) \(window.pop ? "popped" : "slid", privacy: .public) in \(window.frames) frames, \(landed, privacy: .public)")
        }
    }

    /// A Space that still lists the window, or does not read, leaves the pool, since its next
    /// slide would carry the window too (docs/geometry.md).
    private func release(_ space: SpaceID, of id: WindowID) {
        poolChecks.async {
            _ = kosmos_barrier(space)
            let members = SkyLight.windows(in: space)
            guard let members, !members.contains(id) else {
                let why = members == nil ? "its windows did not read" : "\(id) is still in it"
                slideLog.error("animation Space \(space) leaves the pool until recovery: \(why, privacy: .public)")
                return
            }
            if !members.isEmpty {
                slideLog.notice("animation Space \(space) back in the pool with \(members.map(String.init).joined(separator: " "), privacy: .public) in it")
            }
            onMain { self.free.append(space) }
        }
    }

    /// The windows a display frame finished.
    private func ended(_ done: [(WindowID, SlidingWindow)]) {
        for (id, window) in done { finished(id, window) }
        stopIdleLinks()
    }

    private func startLink(on display: DisplayID) -> Bool {
        guard links[display] == nil else { return true }
        guard let screen = NSScreen.screens.first(where: { $0.displayID == display }) else { return false }
        let onscreen = onscreen
        // The link keeps its target. Sent a quarter of a refresh after the vsync, clear of
        // WindowServer's cut-off for the next composite, a frame's transforms and rings land in
        // the same one, a refresh after the target; measured on the built-in display at 120 Hz
        // only (docs/geometry.md).
        let link = screen.displayLink(target: LinkTarget { [weak self] link in
            let calledBack = CACurrentMediaTime()
            let (timestamp, at) = (link.timestamp, link.targetTimestamp)
            let wait = max(0, timestamp + link.duration / 4 - calledBack)
            Onscreen.frames.asyncAfter(deadline: .now() + wait) {
                let done = onscreen.step(on: display, timestamp: timestamp, calledBack: calledBack, at: at)
                if !done.isEmpty { onMain { self?.ended(done) } }
            }
        }, selector: #selector(LinkTarget.frame))
        let rate = Float(screen.maximumFramesPerSecond)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
        onscreen.linkStarted(on: display)
        nonisolated(unsafe) let added = link
        linkThread.perform { added.add(to: .current, forMode: .common) }
        links[display] = link
        return true
    }

    private func stopIdleLinks() {
        let sliding = onscreen.state.withLock { Set($0.windows.values.map(\.display)) }
        for display in Array(links.keys) where !sliding.contains(display) { stopLink(display) }
    }

    private func stopLink(_ display: DisplayID) {
        guard let link = links.removeValue(forKey: display) else { return }
        // After its add, which the link thread may not have run yet. A callback already under
        // way steps nothing, as the link's frames are gone.
        nonisolated(unsafe) let stopped = link
        linkThread.perform { stopped.invalidate() }
        let frames = onscreen.linkStopped(on: display)
        // script/bench-relayout.sh counts this line.
        slideLog.info("""
            slide frames: \(frames.callbacks) callbacks, \(frames.time * 1000, format: .fixed(precision: 2)) ms in them, \
            \(frames.slowest * 1000, format: .fixed(precision: 2)) ms at most, display \(display)
            """)
    }
}

extension SlidingWindow {
    /// Sent under Onscreen's lock, from the links and the reads, so the last one sent is for the
    /// newest frame.
    fileprivate func show() {
        kosmos_space_set_transform(space, Slide.transform(showing: shown, at: actual))
    }
}

/// A border window's ring layer. While its window slides, its frame and opacity are set only
/// under Onscreen's lock, so the last one set is for the newest frame (docs/borders.md).
struct RingLayer: @unchecked Sendable {
    let layer: CALayer
}

/// A sliding window's border windows, one for each of `ring.displays`.
struct HandedRing: Sendable {
    let ring: SlideRing
    let layers: [RingLayer]
}

private final class Onscreen: Sendable {
    struct State: Sendable {
        var windows: [WindowID: SlidingWindow] = [:]
        var rings: [WindowID: HandedRing] = [:]
        /// Windows begun with their ring showing, which no display frame steps until a
        /// hand-off.
        var held: Set<WindowID> = []
        /// The display frames of each running link, for its log line.
        var links: [DisplayID: LinkFrames] = [:]
        var following = false
    }

    struct LinkFrames: Sendable {
        var callbacks = 0, time = 0.0, slowest = 0.0
    }

    let state = Mutex(State())
    private let queue = DispatchQueue(label: "kosmos.slide", qos: .userInteractive)
    /// Each display frame of every display is stepped here.
    static let frames = DispatchQueue(label: "kosmos.slide.frames", qos: .userInteractive)
    /// Reads come every 0.1 ms this long after a window's write, read back or new frame, then
    /// every 1 ms (docs/geometry.md).
    private static let fastFor = 0.02

    /// `state` comes from the lock.
    static func remove(_ id: WindowID, from state: inout State) -> SlidingWindow? {
        guard let window = state.windows.removeValue(forKey: id) else { return nil }
        state.rings[id] = nil
        state.held.remove(id)
        kosmos_space_set_transform(window.space, .identity)
        if window.alpha != 1 { kosmos_space_set_alpha(window.space, 1) }
        var ids = [id]
        kosmos_remove_windows(window.space, &ids, 1)
        return window
    }

    func linkStarted(on display: DisplayID) {
        state.withLock { $0.links[display] = LinkFrames() }
    }

    func linkStopped(on display: DisplayID) -> LinkFrames {
        state.withLock { $0.links.removeValue(forKey: display) } ?? LinkFrames()
    }

    /// Placed at once, around where each window shows. Every held window goes, as the border
    /// update's first hand-off comes once each held window's ring is in it or put back
    /// (BorderPool).
    func hand(_ rings: [WindowID: HandedRing]) {
        state.withLock { state in
            state.rings = rings.filter { state.windows[$0.key] != nil }
            Self.place(state.rings.map { ($0.value, state.windows[$0.key]!) })
            state.held.removeAll()
        }
    }

    func release() {
        state.withLock { $0.held.removeAll() }
    }

    /// Steps the windows sliding on `display` for the target `at`. `timestamp` is the link's
    /// for the callback, and `calledBack` when the callback came. Returns the windows whose
    /// slides ended.
    func step(on display: DisplayID, timestamp: Double, calledBack: Double, at: Double) -> [(WindowID, SlidingWindow)] {
        let began = CACurrentMediaTime()
        var stepped: [(id: WindowID, shown: CGRect, sent: Bool)] = []
        var (locked, transformsSent, ringsPlaced) = (began, began, began)
        var frame = 0
        let done = state.withLock { state -> [(WindowID, SlidingWindow)] in
            locked = CACurrentMediaTime()
            // A callback of a link since stopped.
            guard state.links[display] != nil else { return [] }
            var done: [(WindowID, SlidingWindow)] = []
            var rings: [(HandedRing, SlidingWindow)] = []
            for (id, var window) in state.windows where window.display == display && !state.held.contains(id) {
                let (shown, alpha) = (window.shown, window.alpha)
                if window.step(at: at) {
                    if let window = Self.remove(id, from: &state) { done.append((id, window)) }
                    continue
                }
                if window.shown != shown { window.show() }
                if window.alpha != alpha { kosmos_space_set_alpha(window.space, Float(window.alpha)) }
                state.windows[id] = window
                stepped.append((id, window.shown, window.shown != shown))
                if let ring = state.rings[id], window.shown != shown || window.alpha != alpha { rings.append((ring, window)) }
            }
            transformsSent = CACurrentMediaTime()
            Self.place(rings)
            ringsPlaced = CACurrentMediaTime()
            state.links[display]!.callbacks += 1
            state.links[display]!.time += ringsPlaced - began
            state.links[display]!.slowest = max(state.links[display]!.slowest, ringsPlaced - began)
            frame = state.links[display]!.callbacks
            return done
        }
        guard frame > 0 else { return done }
        // Places each display frame's transform against the frames script/bench-frames.sh
        // captures, and times Onscreen's lock: the wait for it, then the transforms and the
        // rings sent under it, which hold a landing's read that long (docs/geometry.md).
        slideLog.debug("""
            frame \(frame) on display \(display): stepped \((began - timestamp) * 1000, format: .fixed(precision: 2)) ms after \
            the link's timestamp, called back \((calledBack - timestamp) * 1000, format: .fixed(precision: 2)) ms after it, \
            target \((at - timestamp) * 1000, format: .fixed(precision: 2)) ms after it, lock waited \
            \((locked - began) * 1000, format: .fixed(precision: 2)) ms, transforms \
            \((transformsSent - locked) * 1000, format: .fixed(precision: 2)) ms, rings \
            \((ringsPlaced - transformsSent) * 1000, format: .fixed(precision: 2)) ms; \
            \(stepped.map { "\($0.id) shown at \($0.shown)\($0.sent ? "" : ", unchanged")" }.joined(separator: "; "), privacy: .public)
            """)
        return done
    }

    /// In one transaction, under the lock and just after the transforms, so each ring lands in
    /// the composite its window's transform makes. The ring goes in the window of the display
    /// holding the largest part of where its window shows, and the others show none
    /// (docs/borders.md).
    private static func place(_ rings: [(HandedRing, SlidingWindow)]) {
        guard !rings.isEmpty else { return }
        // Explicit, as the frames queue has no run loop to commit an implicit transaction.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (handed, window) in rings {
            let place = handed.ring.place(around: window.shown)
            for (index, ring) in handed.layers.enumerated() {
                let shows = index == place?.index
                if shows { ring.layer.frame = place!.frame }
                let opacity = shows ? Float(window.alpha) : 0
                if ring.layer.opacity != opacity { ring.layer.opacity = opacity }
            }
        }
        CATransaction.commit()
    }

    func follow() {
        let idle = state.withLock { state in
            defer { state.following = true }
            return !state.following
        }
        if idle { queue.async { self.read() } }
    }

    /// A row missing from a read tells nothing.
    private func read() {
        let began = CACurrentMediaTime()
        var ids: [WindowID] = []
        var reads = 0, fast = 0
        while true {
            let now = CACurrentMediaTime()
            let soon = state.withLock { state -> Bool? in
                ids.removeAll(keepingCapacity: true)
                var soon = false
                for (id, window) in state.windows where window.isAwaiting(at: now) {
                    ids.append(id)
                    soon = soon || now - window.changedAt < Self.fastFor
                }
                if ids.isEmpty { state.following = false }
                return ids.isEmpty ? nil : soon
            }
            guard let soon else { break }
            let rows = SkyLight.rows(ids) ?? []
            let read = CACurrentMediaTime()
            let moved = state.withLock { state in
                var moved: [WindowRow] = []
                for row in rows {
                    guard var window = state.windows[row.id], window.isAwaiting(at: read) else { continue }
                    // A landing composited before a read finds it shows the window a refresh at
                    // its new frame, off its slide. docs/geometry.md records this ceiling, why no
                    // API closes it, and the upgrades with their costs.
                    if window.observed(row.frame, at: read) {
                        window.show()
                        moved.append(row)
                    }
                    state.windows[row.id] = window
                }
                return moved
            }
            for row in moved { slideLog.debug("\(row.id) read at \(String(describing: row.frame), privacy: .public), its transform sent") }
            reads += 1
            if soon { fast += 1 }
            usleep(soon ? 100 : 1000)
        }
        // script/bench-relayout.sh counts these lines.
        slideLog.info("slide reads: \(reads), \(fast) of them 0.1 ms apart, over \((CACurrentMediaTime() - began) * 1000, format: .fixed(precision: 1)) ms")
    }
}

/// Called on the link thread.
private final class LinkTarget: NSObject, @unchecked Sendable {
    private let step: @Sendable (CADisplayLink) -> Void

    init(_ step: @escaping @Sendable (CADisplayLink) -> Void) { self.step = step }

    @objc func frame(_ link: CADisplayLink) { step(link) }
}
