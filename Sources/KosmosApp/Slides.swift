import AppKit
import CKosmos
import KosmosCore
import KosmosSkyLight
import Synchronization
import os

private let slideLog = Logger(subsystem: "io.github.st-eez.kosmos", category: "slide")

/// Slides windows to the frames a relayout writes, and pops a new window in, through a pool
/// of Spaces whose transforms show each window where it showed (docs/geometry.md).
@MainActor
final class Slides {
    /// `from` is where WindowServer has the window, nil while a write of Kosmos's still moves it.
    struct Motion {
        var from: CGRect?
        var display: DisplayID
        var pop = false
    }

    /// One above the desktop Space's, where a shown Space draws its window with its transform
    /// and alpha (kosmos-probe space-anim).
    private static let level: Int32 = 1
    private static let poolSize = 8

    private let hiding: Hiding
    var onChange: (@MainActor () -> Void)?
    private let onscreen = Onscreen()
    private var free: [UInt64] = []
    private let poolChecks = DispatchQueue(label: "kosmos.slide.pool", qos: .utility)
    private var links: [DisplayID: Link] = [:]

    private struct Link {
        let link: CADisplayLink
        var callbacks = 0, time = 0.0, slowest = 0.0
    }

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
        var slid = 0, jumped = 0, took = 0
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
            (slid, took, popped) = (slid + 1, took + 1, popped || motion.pop)
        }
        if !ended.isEmpty { stopIdleLinks() }
        if took > 0 { onscreen.follow() }
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

    /// Where the window shows as of its link's last display frame, and at what alpha; nil when
    /// it is not sliding.
    func shown(_ id: WindowID) -> (frame: CGRect, alpha: Double)? {
        onscreen.state.withLock { state in state.windows[id].map { ($0.shown, $0.alpha) } }
    }

    /// A change to the newest write's frame leaves the slide: WindowServer can take it after
    /// the worker read it back, while the user holds the button (docs/geometry.md).
    func changedInPress(_ id: WindowID, to frame: CGRect) {
        guard onscreen.state.withLock({ $0.windows[id].map { !$0.isWrite(frame) } }) == true else { return }
        end(id, "as the user moved it")
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
        guard hiding.guardianReady else { return false }
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
    private func release(_ space: UInt64, of id: WindowID) {
        poolChecks.async {
            _ = kosmos_barrier(space)
            let members = kosmos_space_windows(space) as? [UInt32]
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

    private func frame(_ link: CADisplayLink, on display: DisplayID) {
        let began = CACurrentMediaTime()
        let at = link.targetTimestamp
        let done = onscreen.state.withLock { state in
            var done: [(WindowID, SlidingWindow)] = []
            for (id, var window) in state.windows where window.display == display {
                let (shown, alpha) = (window.shown, window.alpha)
                if window.step(at: at) {
                    if let window = Onscreen.remove(id, from: &state) { done.append((id, window)) }
                    continue
                }
                if window.shown != shown { window.show() }
                if window.alpha != alpha { kosmos_space_set_alpha(window.space, Float(window.alpha)) }
                state.windows[id] = window
            }
            return done
        }
        for (id, window) in done { finished(id, window) }
        if done.isEmpty { onChange?() }
        let spent = CACurrentMediaTime() - began
        links[display]?.callbacks += 1
        links[display]?.time += spent
        if let slowest = links[display]?.slowest, spent > slowest { links[display]?.slowest = spent }
        if !done.isEmpty { stopIdleLinks() }
    }

    private func startLink(on display: DisplayID) -> Bool {
        guard links[display] == nil else { return true }
        guard let screen = NSScreen.screens.first(where: { $0.displayID == display }) else { return false }
        // The link keeps its target.
        let link = screen.displayLink(target: LinkTarget { [weak self] in self?.frame($0, on: display) },
                                      selector: #selector(LinkTarget.frame))
        let rate = Float(screen.maximumFramesPerSecond)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
        link.add(to: .main, forMode: .common)
        links[display] = Link(link: link)
        return true
    }

    private func stopIdleLinks() {
        let sliding = onscreen.state.withLock { Set($0.windows.values.map(\.display)) }
        for display in Array(links.keys) where !sliding.contains(display) { stopLink(display) }
    }

    private func stopLink(_ display: DisplayID) {
        guard let entry = links.removeValue(forKey: display) else { return }
        entry.link.invalidate()
        // script/bench-relayout.sh counts this line.
        slideLog.info("""
            slide frames: \(entry.callbacks) callbacks, \(entry.time * 1000, format: .fixed(precision: 2)) ms in them, \
            \(entry.slowest * 1000, format: .fixed(precision: 2)) ms at most, display \(display)
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

private final class Onscreen: Sendable {
    struct State: Sendable {
        var windows: [WindowID: SlidingWindow] = [:]
        var following = false
    }

    let state = Mutex(State())
    private let queue = DispatchQueue(label: "kosmos.slide", qos: .userInteractive)
    /// Reads come every 0.1 ms this long after a window's write, read back or new frame, then
    /// every 1 ms (docs/geometry.md).
    private static let fastFor = 0.02

    /// `state` comes from the lock.
    static func remove(_ id: WindowID, from state: inout State) -> SlidingWindow? {
        guard let window = state.windows.removeValue(forKey: id) else { return nil }
        kosmos_space_set_transform(window.space, .identity)
        if window.alpha != 1 { kosmos_space_set_alpha(window.space, 1) }
        var ids = [id]
        kosmos_remove_windows(window.space, &ids, 1)
        return window
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
            let rows = SkyLight.rows(ids)
            let read = CACurrentMediaTime()
            state.withLock { state in
                for row in rows {
                    guard var window = state.windows[row.id], window.isAwaiting(at: read) else { continue }
                    if window.observed(row.frame, at: read) { window.show() }
                    state.windows[row.id] = window
                }
            }
            reads += 1
            if soon { fast += 1 }
            usleep(soon ? 100 : 1000)
        }
        // script/bench-relayout.sh counts these lines.
        slideLog.info("slide reads: \(reads), \(fast) of them 0.1 ms apart, over \((CACurrentMediaTime() - began) * 1000, format: .fixed(precision: 1)) ms")
    }
}

@MainActor
private final class LinkTarget: NSObject {
    private let step: @MainActor (CADisplayLink) -> Void

    init(_ step: @escaping @MainActor (CADisplayLink) -> Void) { self.step = step }

    @objc func frame(_ link: CADisplayLink) { step(link) }
}
