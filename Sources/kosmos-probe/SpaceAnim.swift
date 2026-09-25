// kosmos-probe space-anim: can Kosmos animate another app's window with SIP on by putting it
// alone in a shown Space and setting that Space's transform each display frame, so the
// compositor moves it and the app does no work per frame? No bridged operation transforms or
// fades one window, and a transform set on another app's window returns success and does
// nothing on macOS 27, but SLSBridgedSpaceSetTransformOperation and SetAlpha act on a Space.
// The holding Space moves its windows off every display that way (DESIGN.md, section 5.3),
// and float-layer showed that a window added to a Space shown in place renders in it.
//
// Step 1: a stub app with the prohibited activation policy opens one opaque 200 by 150 point
// window at the bottom left of the built-in display. It joins a new Space shown one level
// above the desktop Space's and keeps its ordinary Space. The Space's transform goes to a
// translation of 300 points in x, then 100 in y, a scale of 0.5 alone, then a scale of 0.5
// about the window's top left corner, alone and with the translation in x. After each the
// probe reads the transform back, scans the displays for where WindowServer's hit test names
// the window, reads the hit test at points inside and just outside where the window should
// be, and reads the window's bounds from the window list, SkyLight and Accessibility. The
// translations and the plain scale give the convention: which way the transform maps, which
// way y points, and the point it scales about.
//
// Step 2 runs only if step 1's answer is yes. It moves the window 300 points right along an
// eased path, one step per frame of the built-in display's display link for 240 frames. The
// controls make no call, write the position by Accessibility with the window in its ordinary
// Space only and then in the Space too, and send the identity transform each frame; then the
// Space's transform moves the window, then 6 windows in 6 Spaces. Each run prints the frame
// intervals, the time each call took to send, a barrier after the last, the CPU time of the
// probe, the stub and WindowManager.app (proc_pid_rusage) and of WindowServer (ps, to 10 ms,
// since WindowServer runs as another user and refuses proc_pid_rusage), and the inventory's
// WindowServer events that arrived. `rounds` repeats these runs and prints each process's
// median CPU time. Then the probe times how soon the hit test follows a transform, with and
// without a barrier; reads the hit test and the window list at Space alphas of 0, 0.01, 0.5
// and 1; writes the window's frame by Accessibility together with a transform that keeps it
// where it shows, in both orders, and polls the hit test for the window away from there; and
// times creating 8 such Spaces, moving the window through each, and destroying them.
//
// kosmos-probe space-anim look, for a run at the desk, holds each state of step 1 and each
// Space alpha for a second, so a person can check that the window's pixels go where the hit
// test says and that nothing stays behind at its frame.
//
// The stub can never be the front process and Kosmos leaves it alone, so the probe takes no
// focus. Its window shows for a few seconds. However the probe exits, Ctrl-C included, it
// kills the stub, which takes the window away, then destroys its Spaces; only a SIGKILL
// leaves the Spaces, empty. Needs Accessibility for the terminal; the probe never asks for it.
import AppKit
import CKosmos
import KosmosSkyLight

@MainActor func spaceAnim(rounds: Int, look: Bool) -> Never {
    guard AXIsProcessTrusted() else { print("this terminal needs Accessibility permission"); exit(1) }
    let app = NSApplication.shared   // bridged operations need an AppKit client
    app.setActivationPolicy(.prohibited)
    guard builtInScreen() != nil else { print("no built-in display"); exit(1) }
    installCleanup()
    let probe = SpaceAnim(hold: look ? 1 : 0)
    if let found = probe.step1() {
        print("step 1: yes. \(found.convention.description)")
        probe.step2(found.convention, space: found.space, rounds: rounds)
    } else {
        print("step 1: no")
    }
    probe.finish()
}

/// How a Space's transform places a window, found in step 1. The transform acts in a frame
/// whose y points up when `flipped`, with its origin at `origin`: in CoreGraphics' global
/// coordinates, or relative to the window's top left corner when `followsWindow`. It maps a
/// window's point to where it shows, or the reverse when `inverse`.
struct SpaceTransformConvention {
    var inverse: Bool
    var flipped: Bool
    var followsWindow: Bool
    var origin: CGPoint

    /// The Space transform that shows each point p of the window at `frame` at `shown` applied
    /// to p, both in CoreGraphics' global coordinates.
    func transform(showing shown: CGAffineTransform, for frame: CGRect) -> CGAffineTransform {
        let o = followsWindow ? CGPoint(x: frame.minX + origin.x, y: frame.minY + origin.y) : origin
        let toFrame = CGAffineTransform(a: 1, b: 0, c: 0, d: flipped ? -1 : 1, tx: -o.x, ty: flipped ? o.y : -o.y)
        let inFrame = toFrame.inverted().concatenating(shown).concatenating(toFrame)
        return inverse ? inFrame.inverted() : inFrame
    }

    var description: String {
        "The transform maps \(inverse ? "where the window shows to the window" : "the window to where it shows"), "
            + "with y \(flipped ? "up" : "down") and its origin "
            + (followsWindow ? (origin == .zero ? "at the window's top left corner" : "\(format(origin)) from the window's top left corner")
                             : "at \(format(origin)) in CoreGraphics' global coordinates")
    }
}

@MainActor final class SpaceAnim {
    let stub: KeyStub
    let window: UInt32
    let element: AXUIElement?
    /// The window's frame before any transform, from SkyLight, in CoreGraphics' coordinates.
    let frame: CGRect
    /// The height of the display at the origin, to turn CoreGraphics' points into AppKit's.
    let mainHeight: CGFloat
    /// The displays' bounds in CoreGraphics' coordinates, the built-in display first.
    let displays: [CGRect]
    let level: Int32
    /// How long each state of step 1 and each Space alpha stays on screen after its reads,
    /// for someone at the desk to see it.
    let hold: Double
    /// Every Space the probe created, read back at the end.
    var created: [UInt64] = []
    let tally = EventTally()
    let frames = FrameClock()
    let windowManager = pid(named: "WindowManager"), windowServer = pid(named: "WindowServer")

    init(hold: Double) {
        self.hold = hold
        stub = KeyStub("S", arguments: ["float-stub", "prohibited", "S", "400,200,200,150"])
        track(stub: stub.process)
        window = stub.windows[0]
        mainHeight = NSScreen.screens.first?.frame.height ?? 0
        displays = NSScreen.screens.compactMap { screen -> (builtIn: Bool, bounds: CGRect)? in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return nil }
            return (CGDisplayIsBuiltin(id) != 0, CGDisplayBounds(id))
        }.sorted { $0.builtIn && !$1.builtIn }.map(\.bounds)
        settle(0.3)   // let the window reach the screen
        frame = SkyLight.rows([window]).first?.frame ?? .null
        element = windowElement(stub.pid, window)
        let desktop = Displays.current().currentSpace(at: CGPoint(x: frame.midX, y: frame.midY)) ?? 0
        level = SLSSpaceGetAbsoluteLevel(SkyLight.connection, desktop) + 1
        print("stub window \(window) at \(format(frame)); the desktop Space \(desktop) is at level \(level - 1)")
    }

    /// Step 1. Returns the convention and the Space, with the window in it at the identity
    /// transform, if translation and scale both move where the window is hit as predicted.
    func step1() -> (convention: SpaceTransformConvention, space: UInt64)? {
        guard let space = createSpace() else { return nil }
        add(window, to: space)
        print("Space \(space) at level \(level) reads level \(SLSSpaceGetAbsoluteLevel(SkyLight.connection, space)); "
              + "window in it \(inSpace(window, space)), ordinary Spaces \(kosmos_window_spaces(window) as? [UInt64] ?? [])")
        guard observe(space, "identity", .identity, expect: frame).located?.equalTo(frame, within: 1) == true else {
            print("with the identity transform the hit test does not find the window at its frame")
            return nil
        }

        // Until the translations show otherwise, the expected rectangles assume the transform
        // maps the window to where it shows in CoreGraphics' global coordinates.
        let x = observe(space, "translation of 300 in x", CGAffineTransform(translationX: 300, y: 0),
                        expect: frame.offsetBy(dx: 300, dy: 0))
        guard let moved = x.located, abs(moved.width - frame.width) < 1, abs(abs(moved.minX - frame.minX) - 300) < 1,
              abs(moved.minY - frame.minY) < 1 else {
            print("the hit test did not move by 300 points in x")
            return nil
        }
        let inverse = moved.minX < frame.minX
        let y = observe(space, "translation of 100 in y", CGAffineTransform(translationX: 0, y: 100),
                        expect: frame.offsetBy(dx: 0, dy: 100))
        guard let lifted = y.located, abs(abs(lifted.minY - frame.minY) - 100) < 1, abs(lifted.minX - frame.minX) < 1 else {
            print("the hit test did not move by 100 points in y")
            return nil
        }
        let down = lifted.minY > frame.minY

        // A shown scale of 0.5 needs a transform of 2 when it maps where the window shows to
        // the window. A shown scale of 0.5 about O puts the corner p at O + (p - O) / 2, so
        // O = 2 p' - p. The window then moves by Accessibility, and the scale's O moves with it
        // or stays.
        let scale = inverse ? CGAffineTransform(scaleX: 2, y: 2) : CGAffineTransform(scaleX: 0.5, y: 0.5)
        var fixed: [CGPoint] = []
        for shift in [CGVector.zero, CGVector(dx: 200, dy: -100)] {
            let at = frame.offsetBy(dx: shift.dx, dy: shift.dy)
            if let element, shift != .zero { print("  window moved by Accessibility to \(format(at)): \(setFrame(element, at).map(\.rawValue))") }
            let scaled = observe(space, "scale of \(scale.a)", scale, expect: at.applying(CGAffineTransform(scaleX: 0.5, y: 0.5)))
            guard let small = scaled.located, abs(small.width - frame.width / 2) < 1, abs(small.height - frame.height / 2) < 1 else {
                print("the hit test did not follow the scale to half the window's size")
                return nil
            }
            fixed.append(CGPoint(x: 2 * small.minX - at.minX, y: 2 * small.minY - at.minY))
            print("  so the scale's fixed point is \(format(fixed.last!)), \(format(CGPoint(x: fixed.last!.x - at.minX, y: fixed.last!.y - at.minY))) from the window's top left")
        }
        if let element { _ = setFrame(element, frame) }
        let followsWindow = abs(fixed[1].x - fixed[0].x - 200) < 1 && abs(fixed[1].y - fixed[0].y + 100) < 1
        guard followsWindow || hypot(fixed[1].x - fixed[0].x, fixed[1].y - fixed[0].y) < 1 else {
            print("the scale's fixed point neither stayed nor moved with the window")
            return nil
        }
        // The edges are found to a quarter point, so the fixed point to half a point; windows
        // sit on whole points.
        let origin = followsWindow ? CGPoint(x: (fixed[0].x - frame.minX).rounded(), y: (fixed[0].y - frame.minY).rounded())
                                   : CGPoint(x: fixed[0].x.rounded(), y: fixed[0].y.rounded())
        let convention = SpaceTransformConvention(inverse: inverse, flipped: inverse == down, followsWindow: followsWindow, origin: origin)
        print("  so: \(convention.description)")

        let aboutCorner = CGAffineTransform(a: 0.5, b: 0, c: 0, d: 0.5, tx: frame.minX / 2, ty: frame.minY / 2)
        let halved = observe(space, "scale of 0.5 about the window's top left", convention.transform(showing: aboutCorner, for: frame),
                             expect: frame.applying(aboutCorner))
        let both = aboutCorner.concatenating(CGAffineTransform(translationX: 300, y: 0))
        let combined = observe(space, "the same scale, then a translation of 300 in x", convention.transform(showing: both, for: frame),
                               expect: frame.applying(both))
        let back = observe(space, "identity again", .identity, expect: frame)
        guard halved.predicted, combined.predicted, back.predicted else {
            print("the hit test did not land where the convention predicts")
            return nil
        }
        return (convention, space)
    }

    struct Observation {
        /// Where the hit test names the window, or nil if no display shows it.
        let located: CGRect?
        /// Whether the hit test named the window at every point inside the expected rectangle
        /// and at none just outside it.
        let predicted: Bool
    }

    /// Sets the Space's transform, waits for it with a barrier and 50 ms, and prints the
    /// transform read back, where the hit test names the window, the hit test inside and just
    /// outside `expect` if given, and the window's bounds as the window list, SkyLight and
    /// Accessibility read them.
    @discardableResult
    func observe(_ space: UInt64, _ step: String, _ transform: CGAffineTransform, expect: CGRect?) -> Observation {
        let sent = kosmos_space_set_transform(space, transform)
        _ = kosmos_barrier(space)
        settle(0.05)
        var actual = CGAffineTransform.identity
        let read = kosmos_space_get_transform(space, &actual)
        let start = ContinuousClock.now
        let (located, tests) = locate()
        print("\(step): set \(format(transform)) (sent \(sent)), reads \(read ? format(actual) : "nothing")")
        print("  hit region \(located.map(format) ?? "on no display") (\(tests) hit tests in "
              + String(format: "%.0f ms)", elapsed(start)))
        var predicted = false
        if let expect {
            // Points 3 points either side of each edge's middle, since the corners are round.
            let inside = [CGPoint(x: expect.midX, y: expect.midY),
                          CGPoint(x: expect.minX + 3, y: expect.midY), CGPoint(x: expect.maxX - 3, y: expect.midY),
                          CGPoint(x: expect.midX, y: expect.minY + 3), CGPoint(x: expect.midX, y: expect.maxY - 3)]
            let outside = [CGPoint(x: expect.minX - 3, y: expect.midY), CGPoint(x: expect.maxX + 3, y: expect.midY),
                           CGPoint(x: expect.midX, y: expect.minY - 3), CGPoint(x: expect.midX, y: expect.maxY + 3)]
            let insideHits = inside.map(hit), outsideHits = outside.map(hit)
            predicted = insideHits.allSatisfy { $0 == window } && !outsideHits.contains(window)
            print("  expected \(format(expect)): inside (center, left, right, top, bottom) \(insideHits.map(label).joined(separator: ", ")); "
                  + "just outside (left, right, top, bottom) \(outsideHits.map(label).joined(separator: ", "))")
        }
        print("  bounds: \(bounds())")
        settle(hold)
        return Observation(located: located, predicted: predicted)
    }

    /// The window's bounds as the window list, SkyLight and Accessibility read them.
    func bounds() -> String {
        let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], window) as? [[String: Any]])?.first
        let list = (info?[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) }
        return "window list \(list.map(format) ?? "none"), SkyLight \(SkyLight.rows([window]).first.map { format($0.frame) } ?? "none"), "
            + "AX \(element.map { format(axFrame($0)) } ?? "no element")"
    }

    /// Where WindowServer's hit test names the window: the bounding rectangle of the hits on
    /// a 20 point grid over the built-in display, else over the first other display that has
    /// any, with each edge then found to a quarter point through the hit nearest its middle.
    /// Assumes the region is a rectangle. Returns it, or nil, and the number of hit tests.
    func locate() -> (CGRect?, Int) {
        let step: CGFloat = 20
        var tests = 0
        func hits(_ point: CGPoint) -> Bool {
            tests += 1
            return hit(point) == window
        }
        for bounds in displays {
            var found: [CGPoint] = []
            for y in stride(from: bounds.minY + step / 2, to: bounds.maxY, by: step) {
                for x in stride(from: bounds.minX + step / 2, to: bounds.maxX, by: step) where hits(CGPoint(x: x, y: y)) {
                    found.append(CGPoint(x: x, y: y))
                }
            }
            guard let minX = found.map(\.x).min(), let maxX = found.map(\.x).max(),
                  let minY = found.map(\.y).min(), let maxY = found.map(\.y).max() else { continue }
            let middle = CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
            let anchor = found.min { hypot($0.x - middle.x, $0.y - middle.y) < hypot($1.x - middle.x, $1.y - middle.y) }!
            func edge(_ inside: CGFloat, _ outside: CGFloat, _ point: (CGFloat) -> CGPoint) -> CGFloat {
                var inside = inside, outside = outside
                while abs(outside - inside) > 0.25 {
                    let half = (inside + outside) / 2
                    if hits(point(half)) { inside = half } else { outside = half }
                }
                return (inside + outside) / 2
            }
            let left = edge(anchor.x, minX - step) { CGPoint(x: $0, y: anchor.y) }
            let right = edge(anchor.x, maxX + step) { CGPoint(x: $0, y: anchor.y) }
            let top = edge(anchor.y, minY - step) { CGPoint(x: anchor.x, y: $0) }
            let bottom = edge(anchor.y, maxY + step) { CGPoint(x: anchor.x, y: $0) }
            return (CGRect(x: left, y: top, width: right - left, height: bottom - top), tests)
        }
        return (nil, tests)
    }

    /// The window WindowServer's hit test names at a point in CoreGraphics' coordinates, or 0.
    func hit(_ point: CGPoint) -> UInt32 {
        UInt32(clamping: NSWindow.windowNumber(at: NSPoint(x: point.x, y: mainHeight - point.y), belowWindowWithWindowNumber: 0))
    }

    func label(_ hit: UInt32) -> String {
        if hit == window { return "stub" }
        if hit == 0 { return "none" }
        guard let row = SkyLight.rows([hit]).first else { return "\(hit)" }
        return "\(hit) (\(NSRunningApplication(processIdentifier: row.pid)?.localizedName ?? "pid \(row.pid)"))"
    }

    /// Step 2, with the window in `space` at the identity transform.
    func step2(_ convention: SpaceTransformConvention, space: UInt64, rounds: Int) {
        tally.register()
        tally.watch([window])
        func shift(_ dx: CGFloat) -> CGAffineTransform {
            convention.transform(showing: CGAffineTransform(translationX: dx, y: 0), for: frame)
        }
        func send(_ spaces: [UInt64], _ transform: CGAffineTransform) -> [Double] {
            spaces.map { space in
                let start = ContinuousClock.now
                _ = kosmos_space_set_transform(space, transform)
                return elapsed(start)
            }
        }

        print("step 2: 240 frames, 300 points right along an eased path, \(rounds) rounds")
        var cpu: [(name: String, times: CPUTimes)] = []
        func run(_ name: String, _ step: @escaping (CGFloat) -> [Double]) {
            cpu.append((name, animate(name, space: space, step)))
        }
        for round in 1...rounds {
            print("round \(round)")
            run("control, no call") { _ in [] }
            if let element {
                // Accessibility writes with the window in its ordinary Space only, as Kosmos's
                // animation trial moves windows, then with it in the Space too.
                var ids = [window]
                _ = kosmos_remove_windows(space, &ids, 1)
                _ = kosmos_barrier(space)
                for inSpace in [false, true] {
                    if inSpace { add(window, to: space) }
                    run("control, Accessibility position writes, \(inSpace ? "in the Space too" : "in its ordinary Space only")") { dx in
                        var origin = CGPoint(x: self.frame.minX + dx, y: self.frame.minY)
                        let start = ContinuousClock.now
                        _ = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &origin)!)
                        return [elapsed(start)]
                    }
                    _ = setFrame(element, frame)
                }
            }
            run("control, the identity transform sent each frame") { _ in send([space], .identity) }
            run("1 Space") { send([space], shift($0)) }
            _ = send([space], .identity)

            var spaces = [space], windows = [window]
            for index in 1...5 {
                guard let id = UInt32(stub.send("open \(40 * index),\(20 * index),200,150 0")), let more = createSpace() else { break }
                add(id, to: more)
                spaces.append(more)
                windows.append(id)
            }
            tally.watch(windows)
            run("\(spaces.count) Spaces") { send(spaces, shift($0)) }
            _ = send(spaces, .identity)
            for (more, id) in zip(spaces, windows).dropFirst() {
                var ids = [id]
                _ = kosmos_remove_windows(more, &ids, 1)
                _ = destroySpace(more)
                _ = stub.send("close \(id)")
            }
            tally.watch([window])
        }
        if rounds > 1 {
            print("CPU medians of \(rounds) rounds:")
            var names: [String] = []
            for entry in cpu where !names.contains(entry.name) { names.append(entry.name) }
            for name in names { print("  \(name): \(CPUTimes.median(cpu.filter { $0.name == name }.map(\.times)))") }
        }

        applyLatency(space: space, moved: shift(300))
        alpha(space: space)
        compensate(space: space, shift: shift)
        var ids = [window]
        _ = kosmos_remove_windows(space, &ids, 1)
        _ = kosmos_barrier(space)
        pool(moved: shift(100))
    }

    /// Moves the window 300 points right along a cubic ease in and out, calling `step` with the
    /// offset once per frame of the built-in display's display link for 240 frames, and prints
    /// the frame intervals, the times `step` returns for its calls, a barrier on `space` after
    /// the last frame, the CPU time of each process across the run, and the events that arrived.
    /// Returns the CPU times.
    func animate(_ name: String, space: UInt64, _ step: @escaping (CGFloat) -> [Double]) -> CPUTimes {
        settle(0.3)   // let earlier events arrive
        let events = tally.counts()
        let before = cpuTimes()
        var calls: [Double] = [], perFrame: [Double] = [], ticks: [Double] = [], vsyncs: [CFTimeInterval] = []
        let start = ContinuousClock.now
        frames.run(on: builtInScreen()!) { link in
            ticks.append(elapsed(start))
            vsyncs.append(link.timestamp)
            let t = Double(ticks.count - 1) / 239
            let eased = t < 0.5 ? 4 * t * t * t : 1 - pow(2 - 2 * t, 3) / 2
            let made = step(300 * eased)
            calls += made
            perFrame.append(made.reduce(0, +))
            return ticks.count < 240
        }
        let wall = (ticks.last ?? 0) - (ticks.first ?? 0)
        let drain = ContinuousClock.now
        _ = kosmos_barrier(space)
        let barrier = elapsed(drain)
        let after = cpuTimes()
        settle(0.3)   // let the events arrive
        let intervals = zip(ticks.dropFirst(), ticks).map { $0 - $1 }
        let frameLength = 1000.0 / Double(builtInScreen()?.maximumFramesPerSecond ?? 120)
        let skipped = zip(vsyncs.dropFirst(), vsyncs).filter { ($0 - $1) * 1000 > frameLength * 1.5 }.count
        print(String(format: "%@: %d frames in %.0f ms; callback intervals p50 %.2f, p95 %.2f, max %.2f ms; %d display frames skipped",
                     name, ticks.count, wall, percentile(intervals, 0.5), percentile(intervals, 0.95), percentile(intervals, 1), skipped))
        if !calls.isEmpty {
            print(String(format: "  %d calls: p50 %.3f, p95 %.3f, max %.3f ms; per frame p50 %.3f, p95 %.3f, max %.3f ms",
                         calls.count, percentile(calls, 0.5), percentile(calls, 0.95), percentile(calls, 1),
                         percentile(perFrame, 0.5), percentile(perFrame, 0.95), percentile(perFrame, 1)))
        }
        print(String(format: "  a barrier after the last frame took %.2f ms", barrier))
        print("  CPU: \(after - before)")
        print("  events: \(tally.since(events))")
        return after - before
    }

    /// How soon the hit test names the window where a transform shows it: 20 transforms each
    /// way between identity and `moved`, sent alone and with a barrier after, then the hit
    /// test read without pause at a point only the new place covers, for up to 100 ms.
    func applyLatency(space: UInt64, moved: CGAffineTransform) {
        let there = CGPoint(x: frame.midX + 300, y: frame.midY), here = CGPoint(x: frame.midX, y: frame.midY)
        print("apply latency: the hit test read without pause after each transform, at a point only its new place covers")
        for withBarrier in [false, true] {
            var shown: [Double] = [], afterBarrier: [Double] = [], barriers: [Double] = []
            var firstRead = 0, missed = 0
            for trial in 0..<20 {
                let out = trial % 2 == 0
                let start = ContinuousClock.now
                _ = kosmos_space_set_transform(space, out ? moved : .identity)
                var done = 0.0
                if withBarrier {
                    _ = kosmos_barrier(space)
                    done = elapsed(start)
                    barriers.append(done)
                }
                var reads = 0
                var seen: Double?
                while seen == nil, elapsed(start) < 100 {
                    reads += 1
                    if hit(out ? there : here) == window { seen = elapsed(start) }
                }
                if let seen {
                    shown.append(seen)
                    if withBarrier { afterBarrier.append(seen - done) }
                    if reads == 1 { firstRead += 1 }
                } else {
                    missed += 1
                }
                settle(0.02)
            }
            var line = withBarrier ? "  with a barrier" : "  sent alone"
            line += String(format: ": the hit test followed at the first read %d of 20 times, not within 100 ms %d times; "
                           + "from the send p50 %.3f, p95 %.3f, max %.3f ms", firstRead, missed,
                           percentile(shown, 0.5), percentile(shown, 0.95), percentile(shown, 1))
            if withBarrier {
                line += String(format: "; the barrier took p50 %.3f, max %.3f ms, and the hit test followed %.3f ms after it at most",
                               percentile(barriers, 0.5), percentile(barriers, 1), percentile(afterBarrier, 1))
            }
            print(line)
        }
    }

    /// The hit test at the window's center and the window list's view of it at Space alphas
    /// of 0, 0.01, 0.5 and 1.
    func alpha(space: UInt64) {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        print("Space alpha:")
        for value: Float in [0, 0.01, 0.5, 1] {
            let sent = kosmos_space_set_alpha(space, value)
            _ = kosmos_barrier(space)
            settle(0.05)
            let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], window) as? [[String: Any]])?.first
            let onScreen = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? [])
                .contains { ($0[kCGWindowNumber as String] as? Int) == Int(window) }
            print("  \(value) (sent \(sent)): hit at the window's center \(label(hit(center))); in the on-screen window list \(onScreen), "
                  + "its alpha there \(info?[kCGWindowAlpha as String] as? Double ?? -1), "
                  + "SkyLight ordered in \(SkyLight.rows([window]).first?.orderedIn == true)")
            settle(hold)
        }
    }

    /// Writes the window's frame 300 points right by Accessibility with a transform that keeps
    /// it where it shows, then back with the identity, 20 times in each order, and reads the
    /// hit test without pause for 150 ms after each pair: at the new frame, where it should
    /// not be, and at the frame it shows at, where it should.
    func compensate(space: UInt64, shift: (CGFloat) -> CGAffineTransform) {
        guard let element else { return print("no Accessibility element for the window") }
        let there = CGPoint(x: frame.midX + 300, y: frame.midY), here = CGPoint(x: frame.midX, y: frame.midY)
        print("Accessibility write with a compensating transform, the hit test read for 150 ms after each:")
        for writeFirst in [true, false] {
            var wrongChanges = 0, atNew = 0, missing = 0, reads = 0
            var writes: [Double] = [], wrongFor: [Double] = [], rightBy: [Double] = []
            for trial in 0..<20 {
                let out = trial % 2 == 0
                var origin = CGPoint(x: frame.minX + (out ? 300 : 0), y: frame.minY)
                let transform = out ? shift(-300) : .identity
                func write() {
                    let start = ContinuousClock.now
                    _ = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &origin)!)
                    writes.append(elapsed(start))
                }
                let start = ContinuousClock.now
                if writeFirst { write() }
                _ = kosmos_space_set_transform(space, transform)
                if !writeFirst { write() }
                var first: Double?, last = 0.0
                while elapsed(start) < 150 {
                    reads += 1
                    let seenThere = hit(there) == window, seenHere = hit(here) == window
                    if seenThere { atNew += 1 }
                    if !seenHere { missing += 1 }
                    if seenThere || !seenHere {
                        last = elapsed(start)
                        if first == nil { first = last }
                    }
                }
                if let first {
                    wrongChanges += 1
                    wrongFor.append(last - first)
                    rightBy.append(last)
                }
            }
            var line = writeFirst ? "  write, then transform" : "  transform, then write"
            line += ": \(wrongChanges) of 20 changes showed the window away from its place at some read; of \(reads) reads, "
                + "\(atNew) hit it at the new frame and \(missing) missed it at its place"
            if !wrongFor.isEmpty {
                line += String(format: "; wrong for p50 %.2f, max %.2f ms from the first wrong read to the last, "
                               + "which came p50 %.2f, max %.2f ms after the first call",
                               percentile(wrongFor, 0.5), percentile(wrongFor, 1), percentile(rightBy, 0.5), percentile(rightBy, 1))
            }
            line += String(format: "; the write took p50 %.2f, max %.2f ms", percentile(writes, 0.5), percentile(writes, 1))
            print(line)
        }
        print("  after the last change back: \(bounds())")
    }

    /// Creates 8 Spaces, moves the window through each (add, a transform and back, remove),
    /// and destroys them, timing each step.
    func pool(moved: CGAffineTransform) {
        print("8 Spaces:")
        settle(0.3)   // let earlier events arrive
        var events = tally.counts()
        var before = cpuTimes()
        var creates: [Double] = [], spaces: [UInt64] = []
        for _ in 0..<8 {
            let start = ContinuousClock.now
            guard let space = createSpace() else { break }
            creates.append(elapsed(start))
            spaces.append(space)
        }
        var after = cpuTimes()
        settle(0.3)   // let the events arrive
        print(String(format: "  created %d: p50 %.2f, max %.2f ms each", creates.count, percentile(creates, 0.5), percentile(creates, 1))
              + "; CPU \(after - before); events: \(tally.since(events))")

        events = tally.counts()
        before = cpuTimes()
        var adds: [Double] = [], transforms: [Double] = [], removes: [Double] = [], joined = 0, left = 0
        var ids = [window]
        for space in spaces {
            var start = ContinuousClock.now
            _ = kosmos_add_windows(space, &ids, 1, false)
            _ = kosmos_barrier(space)
            adds.append(elapsed(start))
            if inSpace(window, space) { joined += 1 }
            start = .now
            _ = kosmos_space_set_transform(space, moved)
            _ = kosmos_space_set_transform(space, .identity)
            _ = kosmos_barrier(space)
            transforms.append(elapsed(start))
            start = .now
            _ = kosmos_remove_windows(space, &ids, 1)
            _ = kosmos_barrier(space)
            removes.append(elapsed(start))
            if !inSpace(window, space) { left += 1 }
        }
        after = cpuTimes()
        settle(0.3)
        print(String(format: "  reused: add and barrier p50 %.2f, max %.2f ms (joined %d); two transforms and barrier p50 %.2f, max %.2f ms; "
                     + "remove and barrier p50 %.2f, max %.2f ms (left %d)", percentile(adds, 0.5), percentile(adds, 1), joined,
                     percentile(transforms, 0.5), percentile(transforms, 1), percentile(removes, 0.5), percentile(removes, 1), left)
              + "; CPU \(after - before); events: \(tally.since(events))")

        events = tally.counts()
        before = cpuTimes()
        let start = ContinuousClock.now
        for space in spaces { _ = kosmos_space_destroy(space) }
        let sent = elapsed(start)
        _ = kosmos_barrier(spaces.last ?? 0)
        let barrier = elapsed(start)
        let gone = poll { spaces.allSatisfy { kosmos_space_windows($0) == nil } }
        let readGone = elapsed(start)
        for space in spaces where kosmos_space_windows(space) == nil { untrack(space: space) }
        after = cpuTimes()
        settle(0.3)
        print(String(format: "  destroyed: sent in %.2f ms, then a barrier by %.2f ms; all read gone %@ by %.2f ms",
                     sent, barrier, gone ? "true" : "false", readGone)
              + "; CPU \(after - before); events: \(tally.since(events))")
    }

    /// A new Space at the probe's level, in place and opaque, tracked for cleanup.
    func createSpace() -> UInt64? {
        let space = kosmos_float_space_create(level)
        guard space != 0 else { print("Space not created"); return nil }
        track(space: space)
        created.append(space)
        return space
    }

    /// Adds the window to the Space, keeping its other Spaces, and waits with a barrier.
    func add(_ window: UInt32, to space: UInt64) {
        var ids = [window]
        _ = kosmos_add_windows(space, &ids, 1, false)
        _ = kosmos_barrier(space)
    }

    /// Takes the windows out of every Space still tracked and destroys those, kills the stub,
    /// reads back that every Space the probe created is gone, and exits.
    func finish() -> Never {
        for space in created where kosmos_space_windows(space) != nil {
            var ids = [window]
            _ = kosmos_remove_windows(space, &ids, 1)
            _ = destroySpace(space)
        }
        stub.process.terminate()
        print("stub quit, its window gone: \(poll { SkyLight.rows([window]).isEmpty })")
        let left = created.filter { kosmos_space_windows($0) != nil }
        print("Spaces created: \(created.count); still there: \(left.isEmpty ? "none" : "\(left)")")
        exit(0)
    }

    /// CPU time of the probe, the stub, WindowManager.app and WindowServer.
    func cpuTimes() -> CPUTimes {
        CPUTimes(probe: rusageCPU(getpid()), stub: rusageCPU(stub.pid), windowManager: windowManager.flatMap(rusageCPU),
                 windowServer: windowServer.flatMap(psCPU))
    }
}

/// CPU time in ms, nil where unread.
struct CPUTimes: CustomStringConvertible {
    var probe, stub, windowManager, windowServer: Double?

    static func - (a: CPUTimes, b: CPUTimes) -> CPUTimes {
        func minus(_ a: Double?, _ b: Double?) -> Double? { a.flatMap { a in b.map { a - $0 } } }
        return CPUTimes(probe: minus(a.probe, b.probe), stub: minus(a.stub, b.stub),
                        windowManager: minus(a.windowManager, b.windowManager), windowServer: minus(a.windowServer, b.windowServer))
    }

    /// Each process's median over the runs.
    static func median(_ runs: [CPUTimes]) -> CPUTimes {
        func median(_ values: [Double?]) -> Double? {
            let read = values.compactMap { $0 }
            return read.isEmpty ? nil : percentile(read, 0.5)
        }
        return CPUTimes(probe: median(runs.map(\.probe)), stub: median(runs.map(\.stub)),
                        windowManager: median(runs.map(\.windowManager)), windowServer: median(runs.map(\.windowServer)))
    }

    var description: String {
        func ms(_ value: Double?) -> String { value.map { String(format: "%.1f", $0) } ?? "unread" }
        return "probe \(ms(probe)), stub \(ms(stub)), WindowManager \(ms(windowManager)) ms (proc_pid_rusage); "
            + "WindowServer \(ms(windowServer)) ms (ps)"
    }
}

/// A process's user and system CPU time in ms from proc_pid_rusage, which reads only this
/// user's processes. Its times count Mach ticks.
func rusageCPU(_ pid: pid_t) -> Double? {
    var info = rusage_info_v4()
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
    }
    guard result == 0 else { return nil }
    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    return Double(info.ri_user_time + info.ri_system_time) * Double(timebase.numer) / Double(timebase.denom) / 1e6
}

/// A process's CPU time in ms as ps prints it, "minutes:seconds.hundredths".
func psCPU(_ pid: pid_t) -> Double? {
    let ps = Process()
    ps.executableURL = URL(fileURLWithPath: "/bin/ps")
    ps.arguments = ["-o", "time=", "-p", "\(pid)"]
    let pipe = Pipe()
    ps.standardOutput = pipe
    guard (try? ps.run()) != nil else { return nil }
    let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    ps.waitUntilExit()
    let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":").compactMap { Double($0) }
    return parts.isEmpty ? nil : parts.reduce(0) { $0 * 60 + $1 } * 1000
}

/// The pid of the process with this exact name, from pgrep, which also reads other users'
/// processes.
func pid(named name: String) -> pid_t? {
    let pgrep = Process()
    pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    pgrep.arguments = ["-x", name]
    let pipe = Pipe()
    pgrep.standardOutput = pipe
    guard (try? pgrep.run()) != nil else { return nil }
    let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    pgrep.waitUntilExit()
    return text.split(separator: "\n").first.flatMap { pid_t($0) }
}

/// Counts the inventory's WindowServer events on the probe's connection, by id and by whether
/// they name one of the watched windows. SkyLight calls back on whichever thread read the
/// message, so the counts sit behind a lock.
final class EventTally: @unchecked Sendable {
    private let lock = NSLock()
    private var tallied: [String: Int] = [:]
    private var watched: Set<UInt32> = []

    /// Registers for the ids the inventory uses. Call once.
    func register() {
        let context = Unmanaged.passRetained(self).toOpaque()   // lives for the process
        for id in WindowServerEvent.ids {
            _ = SLSRegisterConnectionNotifyProc(SkyLight.connection, { id, data, length, context, _ in
                guard let context else { return }
                let payload = UnsafeRawBufferPointer(start: data, count: data == nil ? 0 : length)
                Unmanaged<EventTally>.fromOpaque(context).takeUnretainedValue()
                    .record(id, window: WindowServerEvent(id: id, payload: payload)?.window)
            }, id, context)
        }
    }

    /// Asks for the per-window events of these windows only.
    func watch(_ windows: [UInt32]) {
        lock.withLock { watched = Set(windows) }
        SkyLight.watch(windows)
    }

    private func record(_ id: UInt32, window: UInt32?) {
        lock.withLock {
            let key = "\(id)" + (window.map { watched.contains($0) ? " stub" : " other" } ?? "")
            tallied[key, default: 0] += 1
        }
    }

    func counts() -> [String: Int] { lock.withLock { tallied } }

    /// The events counted since `before`, by id.
    func since(_ before: [String: Int]) -> String {
        let now = counts()
        let delta = now.keys.sorted().compactMap { key in
            let n = now[key]! - (before[key] ?? 0)
            return n > 0 ? "\(key) \(n)" : nil
        }
        return delta.isEmpty ? "none" : delta.joined(separator: ", ")
    }
}

/// Runs AppKit's event loop for `seconds`, or until `done`, which SkyLight needs to deliver
/// its notifications.
@MainActor func settle(_ seconds: Double, until done: () -> Bool = { false }) {
    let end = Date(timeIntervalSinceNow: seconds)
    while !done(), let event = NSApp.nextEvent(matching: .any, until: end, inMode: .default, dequeue: true) {
        NSApp.sendEvent(event)
    }
}

/// Calls `body` on the main run loop once per frame of a display until it returns false.
@MainActor final class FrameClock: NSObject {
    private var body: (CADisplayLink) -> Bool = { _ in false }
    private var running = false

    func run(on screen: NSScreen, _ body: @escaping (CADisplayLink) -> Bool) {
        self.body = body
        running = true
        let link = screen.displayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 120, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        while running { settle(0.005, until: { !self.running }) }
        link.invalidate()
    }

    @objc private func tick(_ link: CADisplayLink) {
        if running, !body(link) { running = false }
    }
}

extension CGRect {
    func equalTo(_ other: CGRect, within tolerance: CGFloat) -> Bool {
        abs(minX - other.minX) < tolerance && abs(minY - other.minY) < tolerance
            && abs(width - other.width) < tolerance && abs(height - other.height) < tolerance
    }
}

func format(_ rect: CGRect) -> String {
    String(format: "(%g, %g, %g, %g)", rect.minX, rect.minY, rect.width, rect.height)
}

func format(_ point: CGPoint) -> String { String(format: "(%g, %g)", point.x, point.y) }

func format(_ t: CGAffineTransform) -> String { String(format: "[%g %g %g %g %g %g]", t.a, t.b, t.c, t.d, t.tx, t.ty) }
