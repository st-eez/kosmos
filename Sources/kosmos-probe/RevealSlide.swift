// Whether a window revealed from the holding Space shows through an animation Space's
// transform, so a switch can show a workspace at once and slide its windows to their new
// tiles (docs/hiding.md, docs/geometry.md).
//
//   kosmos-probe reveal-slide [trials] [mode...]
//                                   A red window of a child app, over a black window of the
//                                   probe's, both at floating level so no window of Steve's
//                                   covers them, at the bottom left of the built-in display.
//                                   Each trial conceals the window at A in a holding Space of
//                                   the probe's, reveals it into an animation Space of the
//                                   probe's whose transform shows it at A, and slides it 240
//                                   points right to B as Kosmos slides a window. A strip
//                                   recorded with ScreenCaptureKit gives where each frame shows
//                                   it. Its row, both Spaces' lists, its Space list and the
//                                   window list are read after each step, and Kosmos's batch
//                                   confirmation (ConcealLedger) times the reveal. Each mode
//                                   runs 10 trials by default, or the modes named run alone:
//                                     add        the write to B lands while the window is
//                                                concealed; the reveal adds it to the
//                                                animation Space, then removes it from the
//                                                holding Space
//                                     addgap     add, with 50 ms between the two, to see what
//                                                shows while the window is in both Spaces
//                                     remove     the removal first, then the add
//                                     removegap  remove, with 50 ms between the two
//                                     write      as Kosmos would reveal it: the add, the write
//                                                to B sent, then the removal, with reads of the
//                                                row setting the transform as the write lands
//                                     strip      add, with the window concealed exclusively, so
//                                                on no ordinary Space, and revealed as a batch
//                                                reveals such a window: an exclusive add to the
//                                                current ordinary Space and a barrier before the
//                                                removal
//                                     plain      add, never joining the animation Space, as a
//                                                reveal that does not slide: every frame at B
//                                                shows off the slide. For its stacking against
//                                                the backdrop, which each trial orders the
//                                                window in front of first
//                                   Needs Accessibility and Screen Recording for the terminal,
//                                   and exits rather than ask. A crash leaves both Spaces, empty.
import AppKit
import CKosmos
import KosmosCore
import KosmosSkyLight
import Synchronization

private let revealDistance: CGFloat = 240
private let revealGap = 0.05

private enum RevealMode: String, CaseIterable, Sendable {
    case add, addgap, remove, removegap, write, strip, plain

    var addsFirst: Bool { self != .remove && self != .removegap }
    var gap: Bool { self == .addgap || self == .removegap }
}

/// Where the child's window rests, in CoreGraphics' coordinates.
@MainActor private func revealRest(_ screen: NSScreen) -> CGRect {
    let visible = appKitRect(screen.visibleFrame)
    return CGRect(x: visible.minX + 40, y: visible.maxY - 160, width: 180, height: 120)
}

/// A red titled window at floating level at A on the built-in display, in an app never
/// activated. Prints its id, orders the window front at each line on its standard input, and
/// runs until that closes.
@MainActor func revealWindow() -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let window = NSWindow(contentRect: .zero, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.title = "kosmos-probe reveal"
    window.backgroundColor = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
    window.level = .floating
    window.animationBehavior = .none
    window.isReleasedWhenClosed = false
    window.setFrame(appKitRect(revealRest(builtInScreen())), display: true)
    window.orderFrontRegardless()
    print(window.windowNumber)
    Thread.detachNewThread {
        while readLine() != nil {
            DispatchQueue.main.async { MainActor.assumeIsolated { window.orderFrontRegardless() } }
        }
        exit(0)
    }
    app.run()
    exit(0)
}

/// Keeps the animation Space's transform showing the window where its slide has it, for the
/// frame WindowServer has it at, as Kosmos's display frames and reads do.
private final class RevealFollower: Sendable {
    struct State: Sendable {
        var shown: CGRect
        var actual: CGRect
        var slide: Slide?
        var reading = false
    }

    let state: Mutex<State>
    private let space: UInt64, window: UInt32
    private let queue = DispatchQueue(label: "kosmos-probe.reveal-slide", qos: .userInteractive)

    init(space: UInt64, window: UInt32, at frame: CGRect) {
        (self.space, self.window) = (space, window)
        state = Mutex(State(shown: frame, actual: frame))
    }

    /// `state` comes from the lock.
    private func send(_ state: State) {
        kosmos_space_set_transform(space, Slide.transform(showing: state.shown, at: state.actual))
    }

    func hold(showing shown: CGRect, at actual: CGRect) {
        state.withLock { state in
            (state.shown, state.actual, state.slide) = (shown, actual, nil)
            send(state)
        }
    }

    /// Reads the row every 0.1 ms, as Kosmos does within 20 ms of a write.
    func startReading() {
        state.withLock { $0.reading = true }
        queue.async {
            while self.state.withLock({ $0.reading }) {
                if let frame = SkyLight.rows([self.window])?.first?.frame {
                    self.state.withLock { state in
                        guard state.reading, frame != state.actual else { return }
                        state.actual = frame
                        self.send(state)
                    }
                }
                usleep(100)
            }
        }
    }

    func stopReading() {
        state.withLock { $0.reading = false }
        queue.sync {}
    }

    func begin(_ slide: Slide) { state.withLock { $0.slide = slide } }

    /// True while the slide runs.
    func step(at time: Double) -> Bool {
        state.withLock { state in
            guard let slide = state.slide else { return false }
            let shown = slide.shown(at: time).frame
            if shown != state.shown {
                state.shown = shown
                send(state)
            }
            if slide.isOver(at: time) { state.slide = nil }
            return true
        }
    }
}

@MainActor private final class RevealLink: NSObject {
    private var link: CADisplayLink?
    private let follower: RevealFollower

    init(_ screen: NSScreen, rate: Int, follower: RevealFollower) {
        self.follower = follower
        super.init()
        let link = screen.displayLink(target: self, selector: #selector(tick))
        let rate = Float(rate)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) { _ = follower.step(at: link.targetTimestamp) }

    func stop() {
        link?.invalidate()
        link = nil
    }
}

/// What WindowServer says of the window after a step.
private struct RevealState {
    let step: String
    let inHolding: Bool?, inSlide: Bool?
    let spaces: [UInt64]?
    let row: CGRect?, orderedIn: Bool?
    /// The window list's bounds, which follow the transform, and whether it lists the window on screen.
    let listed: CGRect?, onscreen: Bool?
    /// Whether the on screen window list puts it in front of the backdrop.
    let overBackdrop: Bool?

    func line(from origin: CGRect) -> String {
        func place(_ frame: CGRect?) -> String {
            frame.map { String(format: "x %+.0f", $0.minX - origin.minX) } ?? "none"
        }
        func flag(_ value: Bool?) -> String { value.map { $0 ? "yes" : "no" } ?? "unread" }
        return "\(step): holding \(flag(inHolding)), animation \(flag(inSlide)), Spaces \(spaces.map { "\($0)" } ?? "unread"), "
            + "row \(place(row)) ordered in \(flag(orderedIn)), window list \(place(listed)) on screen \(flag(onscreen)), "
            + "over the backdrop \(flag(overBackdrop))"
    }
}

private struct RevealTrial {
    let mode: RevealMode
    var states: [RevealState] = []
    /// On CACurrentMediaTime's clock.
    var revealed = 0.0, first = 0.0, second = 0.0, slideStart = 0.0, slideEnd = 0.0
    /// ms from the removal to the batch's confirmation, and whether it took the barrier.
    var confirmed: Double?
    var barrier = false
    /// Whether the add to an ordinary Space landed, for a stripped window.
    var added: Bool?
}

@MainActor func revealSlide(trials count: Int, modes: [String]) -> Never {
    let named = modes.map(RevealMode.init(rawValue:))
    guard !named.contains(nil) else { usage() }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    guard let screen = NSScreen.screens.first(where: { CGDisplayIsBuiltin($0.displayID) != 0 }) else {
        print("error: the built-in display is off")
        exit(1)
    }
    // Asking would show a prompt.
    guard AXIsProcessTrusted() else {
        print("error: this terminal has no Accessibility permission")
        exit(1)
    }
    guard CGPreflightScreenCaptureAccess() else {
        print("error: this terminal has no Screen Recording permission")
        exit(1)
    }
    let rate = max(screen.maximumFramesPerSecond, 1), scale = screen.backingScaleFactor
    let bounds = CGDisplayBounds(screen.displayID)
    let rest = revealRest(screen), end = rest.offsetBy(dx: revealDistance, dy: 0)
    let path = rest.union(end).insetBy(dx: -24, dy: -24)

    let backdrop = NSWindow(contentRect: appKitRect(path), styleMask: [.borderless], backing: .buffered, defer: false)
    backdrop.backgroundColor = .black
    backdrop.hasShadow = false
    backdrop.level = .floating
    backdrop.ignoresMouseEvents = true
    backdrop.animationBehavior = .none
    backdrop.isReleasedWhenClosed = false
    backdrop.collectionBehavior = [.transient, .ignoresCycle]
    backdrop.orderFrontRegardless()

    let child = Child(["reveal-window"])
    let window = child.readWindows()[0]
    var found: AXUIElement?
    for _ in 0..<40 where found == nil {
        found = windowElement(child.pid, window)
        if found == nil { pumpEvents(0.05) }
    }
    guard let found else {
        print("error: Accessibility lists no window \(window) for pid \(child.pid)")
        child.terminate()
        exit(1)
    }
    AXUIElementSetMessagingTimeout(found, 1)
    nonisolated(unsafe) let element = found
    let holding = kosmos_holding_create(), slideSpace = kosmos_float_space_create(1)
    guard holding != 0, slideSpace != 0 else {
        print("error: a Space was not created")
        if holding != 0 { kosmos_space_destroy(holding) }
        if slideSpace != 0 { kosmos_space_destroy(slideSpace) }
        child.terminate()
        exit(1)
    }
    var ids = [window]
    let follower = RevealFollower(space: slideSpace, window: window, at: rest)
    let link = RevealLink(screen, rate: rate, follower: follower)

    // A strip 4 points tall across the path, 40 points above the window's bottom edge, in the
    // display's points from its top left. The reader gives the red's left edge in points from A.
    let strip = CGRect(x: path.minX - bounds.minX, y: rest.maxY - 40 - bounds.minY - 2, width: path.width, height: 4)
    let capture = StripCapture(displayID: screen.displayID, strip: strip, scale: scale, rate: rate) { row, width in
        let pixels = CGFloat(width) / strip.width
        func red(_ x: Int) -> Bool {
            let pixel = row[x]
            return (pixel >> 16) & 0xff > 160 && (pixel >> 8) & 0xff < 100 && pixel & 0xff < 100
        }
        guard let first = (0..<width).first(where: red) else { return (nil, nil) }
        return (Double(path.minX + CGFloat(first) / pixels - rest.minX), nil)
    }
    capture.start()
    let started = Date()
    while capture.frames.withLock({ $0.isEmpty }), Date().timeIntervalSince(started) < 3 { pumpEvents(0.05) }
    func cleanUp() {
        capture.stop()
        link.stop()
        follower.stopReading()
        kosmos_remove_windows(holding, &ids, 1)
        kosmos_space_set_transform(slideSpace, .identity)
        kosmos_remove_windows(slideSpace, &ids, 1)
        _ = kosmos_barrier(slideSpace)
        kosmos_space_destroy(holding)
        kosmos_space_destroy(slideSpace)
        backdrop.orderOut(nil)
        child.quit()
    }
    guard !capture.frames.withLock({ $0.isEmpty }) else {
        print("error: the capture sent no frame\(capture.failure.withLock { $0.map { ": \($0)" } ?? "" })")
        cleanUp()
        exit(1)
    }
    print(String(format: "built-in display at %d Hz, %.0fx; window %d of pid %d, %.0f by %.0f at A (%.0f, %.0f), B %.0f points right; "
                 + "holding Space %llu, animation Space %llu",
                 rate, scale, window, child.pid, rest.width, rest.height, rest.minX, rest.minY, revealDistance, holding, slideSpace))

    let writes = DispatchQueue(label: "kosmos-probe.reveal-slide.writes", qos: .userInitiated)
    let bridge = DispatchQueue(label: "kosmos-probe.reveal-slide.bridge", qos: .userInteractive)
    func write(_ frame: CGRect) {
        writes.async {
            var origin = frame.origin
            AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &origin)!)
        }
    }
    func rowFrame() -> CGRect? { SkyLight.rows([window])?.first?.frame }
    /// Waits up to 0.5 s for the row to show the frame.
    func land(_ frame: CGRect) -> Bool {
        let deadline = CACurrentMediaTime() + 0.5
        while CACurrentMediaTime() < deadline {
            if rowFrame() == frame { return true }
            pumpEvents(0.002)
        }
        return false
    }
    func state(_ step: String) -> RevealState {
        _ = kosmos_barrier(slideSpace)
        let row = SkyLight.rows([window])?.first
        let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], window) as? [[String: Any]])?.first
        let listed = (info?[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) }
        let order = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? [])
            .compactMap { $0[kCGWindowNumber as String] as? UInt32 }
        var over: Bool?
        if let own = order.firstIndex(of: window), let under = order.firstIndex(of: UInt32(backdrop.windowNumber)) { over = own < under }
        return RevealState(step: step, inHolding: SkyLight.windows(in: holding).map { $0.contains(window) },
                           inSlide: SkyLight.windows(in: slideSpace).map { $0.contains(window) }, spaces: SkyLight.spaces(of: window),
                           row: row?.frame, orderedIn: row?.orderedIn, listed: listed,
                           onscreen: info.map { ($0[kCGWindowIsOnscreen as String] as? Bool) ?? false }, overBackdrop: over)
    }

    let chosen = named.isEmpty ? RevealMode.allCases : named.compactMap { $0 }
    for mode in chosen {
        var results: [RevealTrial] = []
        for _ in 1...count {
            var trial = RevealTrial(mode: mode)
            child.send("front")
            pumpEvents(0.05)
            trial.states.append(state("ordered front"))
            kosmos_add_windows(holding, &ids, 1, mode == .strip)
            trial.states.append(state(mode == .strip ? "concealed and stripped" : "concealed"))
            pumpEvents(0.1)
            if mode != .write {
                write(end)
                if !land(end) { print("  the write to B did not land in 0.5 s") }
                trial.states.append(state("written to B while concealed"))
            }
            // Kosmos's batch for this reveal, confirmed as Hiding confirms one.
            let batch = ConcealLedger(entries: [window: holding]).batch(show: [window], hide: [], into: holding,
                                                                        isOnAnySpace: { SkyLight.spaces(of: $0)?.isEmpty == false })
            follower.hold(showing: rest, at: rowFrame() ?? rest)
            // A random point of the refresh, as a command's.
            pumpEvents(0.1 + Double.random(in: 0..<(1 / Double(rate))))
            trial.revealed = CACurrentMediaTime()
            func add() {
                if mode != .plain { kosmos_add_windows(slideSpace, &ids, 1, false) }
                if mode == .write {
                    follower.startReading()
                    write(end)
                }
            }
            /// As Hiding sends a batch: a window on no ordinary Space is added to one first,
            /// exclusively, and leaves the holding Space once the add landed. Then the batch is
            /// confirmed as Hiding confirms one.
            func remove() {
                let removal = CACurrentMediaTime()
                var removals = batch.removals
                if !batch.adds.isEmpty {
                    let displays = Displays.current()
                    guard let ordinary = displays.ordinarySpace(original: nil) else { return print("  no ordinary Space") }
                    kosmos_add_windows(ordinary, &ids, 1, true)
                    _ = kosmos_barrier(holding)
                    removals = batch.removals(landed: displays.isInOrdinarySpace)
                    trial.added = displays.isInOrdinarySpace(window)
                }
                let sent = removals
                let send: @Sendable () -> Void = {
                    for (space, windows) in sent {
                        var list = windows
                        kosmos_remove_windows(space, &list, list.count)
                    }
                }
                // Kosmos adds on the main thread and removes on its bridge queue.
                if mode == .write { bridge.sync(execute: send) } else { send() }
                let deadline = CACurrentMediaTime() + 0.01
                func members() -> [SpaceID: Set<WindowID>] {
                    SkyLight.windows(in: holding).map { [holding: Set($0)] } ?? [:]
                }
                var done = batch.isDone(members: members())
                while !done && CACurrentMediaTime() < deadline {
                    usleep(100)
                    done = batch.isDone(members: members())
                }
                if !done {
                    trial.barrier = true
                    done = kosmos_barrier(holding) && batch.isDone(members: members())
                }
                if done { trial.confirmed = (CACurrentMediaTime() - removal) * 1000 }
            }
            if mode.addsFirst { add() } else { remove() }
            trial.first = CACurrentMediaTime()
            if mode.gap {
                pumpEvents(revealGap)
                trial.states.append(state(mode.addsFirst ? "in both Spaces" : "in neither"))
            }
            trial.second = CACurrentMediaTime()
            if mode.addsFirst { remove() } else { add() }
            if mode != .write { follower.startReading() }
            trial.slideStart = CACurrentMediaTime()
            follower.begin(.move(from: rest, to: end, at: trial.slideStart))
            trial.states.append(state("revealed, sliding"))
            pumpEvents(Slide.moveDuration + 0.1)
            trial.slideEnd = trial.slideStart + Slide.moveDuration
            trial.states.append(state("slide over"))
            follower.stopReading()
            kosmos_space_set_transform(slideSpace, .identity)
            kosmos_remove_windows(slideSpace, &ids, 1)
            trial.states.append(state("out of the animation Space"))
            results.append(trial)
            write(rest)
            if !land(rest) { print("  the write back to A did not land in 0.5 s") }
            pumpEvents(0.15)
        }
        reportReveals(mode, results, frames: capture.frames.withLock { $0 }, origin: rest, scale: scale, refresh: 1 / Double(rate))
    }
    cleanUp()
    exit(0)
}

/// Where each frame from the reveal to the slide's end showed the window, in points from A. A
/// frame is on the slide when it shows the window between where the slide had it three
/// refreshes before and where it has it at the frame, and at A before the slide starts.
@MainActor private func reportReveals(_ mode: RevealMode, _ trials: [RevealTrial], frames: [Seen], origin: CGRect, scale: CGFloat,
                                      refresh: Double) {
    func ms(_ seconds: Double) -> String { String(format: "%.1f", seconds * 1000) }
    let tolerance = 2 / Double(scale)
    var off = 0, offFrames = 0, lost = 0, gapShown = 0, gapFrames = 0
    var confirms: [Double] = [], barriers = 0, latencies: [Double] = [], added = 0
    var lines: [String] = []
    for (index, trial) in trials.enumerated() {
        let slide = Slide.move(from: origin, to: origin.offsetBy(dx: revealDistance, dy: 0), at: trial.slideStart)
        func expected(_ time: Double) -> Double { time < trial.slideStart ? 0 : Double(slide.shown(at: time).frame.minX - origin.minX) }
        let after = frames.filter { $0.time >= trial.first && $0.time <= trial.slideEnd + 0.05 }
        let firstShown = after.first { $0.window != nil }
        if let firstShown { latencies.append(firstShown.time - trial.revealed) }
        let offSlide = after.filter { frame in
            guard let place = frame.window else { return false }
            return place < expected(frame.time - 3 * refresh) - tolerance || place > expected(frame.time) + tolerance
        }
        if !offSlide.isEmpty { off += 1 }
        offFrames += offSlide.count
        let shownFrom = firstShown?.time ?? .infinity
        if after.contains(where: { $0.time > shownFrom && $0.window == nil }) { lost += 1 }
        if mode.gap {
            // The capture sends only frames that changed.
            let during = after.filter { $0.time < trial.second }
            gapFrames += during.count
            gapShown += during.filter { $0.window != nil }.count
        }
        if let confirmed = trial.confirmed { confirms.append(confirmed) }
        if trial.added == true { added += 1 }
        if trial.barrier { barriers += 1 }
        let places = after.prefix(14).map { frame in
            let place = frame.window.map { String(format: "%.0f", $0) } ?? "-"
            return (offSlide.contains { $0.time == frame.time } ? place + "!" : place) + "@" + ms(frame.time - trial.first)
        }.joined(separator: " ")
        lines.append("  \(index + 1): first shown \(firstShown.map { ms($0.time - trial.revealed) + " ms after the first call" } ?? "never"), "
                     + "slide started \(ms(trial.slideStart - trial.revealed)) ms after it, "
                     + "confirmed \(trial.confirmed.map { String(format: "%.2f ms after the removal", $0) } ?? "not")\(trial.barrier ? " by barrier" : ""); "
                     + "frames: \(places)")
        if index == 0 { trial.states.forEach { lines.append("     " + $0.line(from: origin)) } }
    }
    print("\(mode.rawValue): off its slide in \(off) of \(trials.count) trials, \(offFrames) frames in all; "
          + "gone after first shown in \(lost)" + (mode == .strip ? "; the add to an ordinary Space landed in \(added)" : "") + (mode.gap ? "; \(gapFrames) frames changed in the gaps, \(gapShown) of them showing it" : ""))
    print("  first shown \(latencies.isEmpty ? "-" : ms(percentile(latencies, 0.5))) ms after the first call at the median, "
          + "\(latencies.max().map(ms) ?? "-") at most; confirmed in \(confirms.count) of \(trials.count), "
          + "\(confirms.isEmpty ? "-" : String(format: "%.2f", percentile(confirms, 0.5))) ms after the removal at the median, "
          + "\(confirms.max().map { String(format: "%.2f", $0) } ?? "-") at most, \(barriers) by barrier")
    let stacking = ["ordered front", "revealed, sliding", "out of the animation Space"].map { step in
        let over = trials.filter { $0.states.first { $0.step == step }?.overBackdrop == true }.count
        return "\(step) \(over)"
    }
    print("  over the backdrop, of \(trials.count): \(stacking.joined(separator: ", "))")
    print("  per trial, points from A of each frame from the first call, - for none and ! off the slide; states of trial 1:")
    lines.forEach { print($0) }
}
