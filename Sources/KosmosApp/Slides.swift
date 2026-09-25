import AppKit
import CKosmos
import KosmosCore
import KosmosSkyLight
import Synchronization
import os

private let slideLog = Logger(subsystem: "io.github.st-eez.kosmos", category: "slide")

/// Slides windows to the frames a relayout writes, and pops a new window in
/// (docs/geometry.md). A window that slides joins a Space of the pool, shown in place at
/// level 1, and keeps its ordinary Space. Its frame goes through the ordinary frame path once,
/// and the Space's transform shows it where it showed, eased to its frame (SlidingWindow);
/// then the window leaves the Space. A display link per display steps the windows sliding on
/// that display, and reads off the main thread follow each write until it lands (Onscreen).
@MainActor
final class Slides {
    /// How a write slides: from `from`, where WindowServer has the window, which is nil while
    /// a write of Kosmos's still moves it; stepped by `display`'s link; popping in when the
    /// window is new.
    struct Motion {
        var from: CGRect?
        var display: DisplayID
        var pop = false
    }

    /// One level above the desktop Space's, 0, where a window alone in a shown Space is drawn
    /// with the Space's transform and alpha (kosmos-probe space-anim, branch spaceanim).
    private static let level: Int32 = 1
    /// The Spaces made at the first turn on. A window that finds none free jumps.
    private static let poolSize = 8

    private let hiding: Hiding
    private let onscreen = Onscreen()
    /// Spaces of the pool that hold no window.
    private var free: [UInt64] = []
    private var links: [DisplayID: Link] = [:]

    /// A display's link, with its callbacks since it started and their time, for the log.
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

    /// Takes the frame writes about to go to the workers, before they are queued, so a window
    /// joins its Space before its app takes the frame. `sliding` holds the writes that slide
    /// (Controller.motions). A new slide jumps while the guardian is not ready, with no Space
    /// free, or with nowhere known to start from. A write that does not slide ends the
    /// window's slide at once, unless it is to the slide's target (SlidingWindow.wrote).
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

    /// The worker read the window's frame back after writing `target` (SlidingWindow.confirmed).
    func confirmed(_ id: WindowID, target: CGRect, readBack: CGRect) {
        let now = CACurrentMediaTime()
        onscreen.state.withLock { $0.windows[id]?.confirmed(target: target, readBack: readBack, at: now) }
    }

    /// Ends at once the slide of each window `visible` rejects, as one concealed, parked,
    /// closed or on a workspace no longer shown, before a batch conceals it, and of each
    /// window on a display of `fullscreen`.
    func keep(_ visible: (WindowID) -> Bool, fullscreen: Set<DisplayID>) {
        let displays = onscreen.state.withLock { $0.windows.mapValues(\.display) }
        for (id, display) in displays where !visible(id) || fullscreen.contains(display) { end(id, "as it left the screen") }
    }

    /// The window changed to `frame` during a press: the user moved or resized it, and its
    /// slide's transform would hold it where the slide shows it, so the slide ends at once.
    /// A change to where its newest write puts it leaves the slide, since WindowServer can take
    /// the write's frame after the worker read it back, while the user holds the button on
    /// another window (SlidingWindow.isWrite).
    func changedInPress(_ id: WindowID, to frame: CGRect) {
        guard onscreen.state.withLock({ $0.windows[id].map { !$0.isWrite(frame) } }) == true else { return }
        end(id, "as the user moved it")
    }

    /// Ends the window's slide at once, and it shows at its own frame. `why` goes to the log.
    func end(_ id: WindowID, _ why: String) {
        guard let window = onscreen.state.withLock({ Onscreen.remove(id, from: &$0) }) else { return }
        finished(id, window, why)
        stopIdleLinks()
    }

    /// Ends every slide and stops every display link, one whose display went too, so the next
    /// slide starts a link on a display that has a screen.
    func endAll(_ why: String) {
        let all = onscreen.state.withLock { state in
            Array(state.windows.keys).compactMap { id in Onscreen.remove(id, from: &state).map { (id, $0) } }
        }
        for (id, window) in all { finished(id, window, why) }
        for display in Array(links.keys) { stopLink(display) }
    }

    /// Starts a slide: the window joins a free Space, whose alpha a pop sets to 0 first, so
    /// the window shows nothing until it pops in. False when it jumps instead.
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

    /// Frees the Space of a window whose slide ended, and logs the slide. `why` says why it
    /// ended before it was done.
    private func finished(_ id: WindowID, _ window: SlidingWindow, _ why: String? = nil) {
        free.append(window.space)
        // script/bench-relayout.sh counts these lines.
        let landed = window.landed.map { String(format: "landed %.1f ms after its write", ($0 - window.sent) * 1000) } ?? "did not land"
        if let why {
            slideLog.info("\(id) slide ended \(why, privacy: .public) after \(window.frames) frames, \(landed, privacy: .public)")
        } else {
            slideLog.info("\(id) \(window.pop ? "popped" : "slid", privacy: .public) in \(window.frames) frames, \(landed, privacy: .public)")
        }
    }

    /// One frame of `display`: each window sliding there shows where its slide has it at the
    /// time the frame shows, and a slide that is done ends.
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
        let spent = CACurrentMediaTime() - began
        links[display]?.callbacks += 1
        links[display]?.time += spent
        if let slowest = links[display]?.slowest, spent > slowest { links[display]?.slowest = spent }
        if !done.isEmpty { stopIdleLinks() }
    }

    /// Starts `display`'s link unless it runs, at the display's own rate. False when no
    /// screen has that display.
    private func startLink(on display: DisplayID) -> Bool {
        guard links[display] == nil else { return true }
        let number = NSDeviceDescriptionKey("NSScreenNumber")
        guard let screen = NSScreen.screens.first(where: { ($0.deviceDescription[number] as? NSNumber)?.uint32Value == display })
        else { return false }
        // The link keeps its target.
        let link = screen.displayLink(target: LinkTarget { [weak self] in self?.frame($0, on: display) },
                                      selector: #selector(LinkTarget.frame))
        let rate = Float(screen.maximumFramesPerSecond)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
        link.add(to: .main, forMode: .common)
        links[display] = Link(link: link)
        return true
    }

    /// Stops the links of the displays no window slides on.
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
    /// Sends the transform that shows the window at `shown` from `actual`. The display links
    /// and the reads send it under Onscreen's lock, so the last one sent is for the newest
    /// frame.
    fileprivate func show() {
        kosmos_space_set_transform(space, Slide.transform(showing: shown, at: actual))
    }
}

/// The sliding windows, which the display links and the reads share, and the reads.
private final class Onscreen: Sendable {
    struct State: Sendable {
        var windows: [WindowID: SlidingWindow] = [:]
        var following = false
    }

    let state = Mutex(State())
    private let queue = DispatchQueue(label: "kosmos.slide", qos: .userInteractive)
    /// Reads come every 0.1 ms while a window's write was queued or read back, or its frame
    /// changed, within this long, and every 1 ms otherwise (docs/geometry.md).
    private static let fastFor = 0.02

    /// Takes the window out of `state` and out of its Space, back at identity and alpha 1,
    /// so it shows at its own frame. `state` comes from the lock.
    static func remove(_ id: WindowID, from state: inout State) -> SlidingWindow? {
        guard let window = state.windows.removeValue(forKey: id) else { return nil }
        kosmos_space_set_transform(window.space, .identity)
        if window.alpha != 1 { kosmos_space_set_alpha(window.space, 1) }
        var ids = [id]
        kosmos_remove_windows(window.space, &ids, 1)
        return window
    }

    /// Starts the reads unless they run.
    func follow() {
        let idle = state.withLock { state in
            defer { state.following = true }
            return !state.following
        }
        if idle { queue.async { self.read() } }
    }

    /// Reads the rows of the windows whose writes have not landed, as Hiding reads a batch's
    /// Spaces, until none is left. At each new frame WindowServer gives a window, its
    /// transform keeps it where it shows. A row missing from a read tells nothing.
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

/// The display link's target, since CADisplayLink calls an Objective-C selector. The link
/// runs on the main run loop.
@MainActor
private final class LinkTarget: NSObject {
    private let step: @MainActor (CADisplayLink) -> Void

    init(_ step: @escaping @MainActor (CADisplayLink) -> Void) { self.step = step }

    @objc func frame(_ link: CADisplayLink) { step(link) }
}
