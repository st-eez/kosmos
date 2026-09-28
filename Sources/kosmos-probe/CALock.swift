// Whether the main thread's AppKit calls on a border window at a slide's start hold Core
// Animation's global lock, which a ring's transaction on another thread takes
// (docs/borders.md).
//
//   kosmos-probe ca-lock [trials] [busy]
//                                   A red window of the probe's, at the bottom left of the
//                                   built-in display, joins an animation Space of the probe's, as
//                                   a slide starts, and at once a border window of the probe's is
//                                   framed to cover the display and ordered in below it, as Kosmos
//                                   readies one; then the window leaves the Space and the border
//                                   window is ordered out, as at the slide's end, and a new border
//                                   window is made, ordered in and out, as Kosmos makes one. Meanwhile a
//                                   thread moves the ring of a second border window, covering the
//                                   display, in an explicit CATransaction every 0.2 ms, as the
//                                   slide's display frames do. Gives each AppKit call's time and
//                                   the longest ring transaction under way during it. A last
//                                   trial holds CATransaction.lock() on the main thread for 5 ms,
//                                   to show the ring's transaction waits for it. 20 trials by
//                                   default. With busy, two more threads read the whole window
//                                   list from WindowServer without pause, so its answers come
//                                   slowly, as at a slide's start. A crash leaves the Space,
//                                   empty.
import AppKit
import CKosmos
import Synchronization

/// A span of time on CACurrentMediaTime's clock.
private struct Span: Sendable {
    let start: Double, end: Double
    var ms: Double { (end - start) * 1000 }
    func overlaps(_ other: Span) -> Bool { start < other.end && other.start < end }
}

@MainActor func caLock(trials: Int, busy: Bool) -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let screen = builtInScreen()
    let visible = appKitRect(screen.visibleFrame)
    let rest = CGRect(x: visible.minX + 40, y: visible.maxY - 140, width: 160, height: 100)
    let target = NSWindow(contentRect: appKitRect(rest), styleMask: [.borderless], backing: .buffered, defer: false)
    target.backgroundColor = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
    target.hasShadow = false
    target.ignoresMouseEvents = true
    target.animationBehavior = .none
    target.isReleasedWhenClosed = false
    target.collectionBehavior = [.transient, .ignoresCycle]
    target.orderFrontRegardless()
    let green = CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)
    // The sliding ring's window, covering the display, and the window each trial readies.
    let sliding = ProbeBorder(), ready = ProbeBorder()
    sliding.place(around: appKitRect(rest), radius: 0, color: green)
    sliding.window.setFrame(screen.frame, display: false)
    sliding.window.order(.below, relativeTo: target.windowNumber)
    ready.place(around: appKitRect(rest), radius: 0, color: green)
    let space = kosmos_float_space_create(1)
    guard space != 0 else {
        print("error: no animation Space")
        exit(1)
    }

    // Each ring transaction, and before it the wait for the lock alone, so a transaction that
    // waited on WindowServer tells apart from one that waited for the lock.
    let rings = Mutex<[(lock: Span, ring: Span)]>([])
    let running = Atomic<Bool>(true)
    nonisolated(unsafe) let ring = sliding.ring
    let origin = appKitRect(rest).insetBy(dx: -2, dy: -2).offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
    let mover = Thread {
        var step = 0
        while running.load(ordering: .relaxed) {
            step += 1
            let locking = CACurrentMediaTime()
            CATransaction.lock()
            let start = CACurrentMediaTime()
            CATransaction.unlock()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            ring.frame = origin.offsetBy(dx: CGFloat(step % 2), dy: 0)
            CATransaction.commit()
            let span = Span(start: start, end: CACurrentMediaTime())
            rings.withLock { $0.append((Span(start: locking, end: start), span)) }
            usleep(200)
        }
    }
    mover.qualityOfService = .userInteractive
    mover.start()
    for _ in 0..<(busy ? 2 : 0) {
        Thread {
            while running.load(ordering: .relaxed) { _ = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) }
        }.start()
    }
    pumpEvents(0.3)

    var calls: [(name: String, span: Span)] = []
    func timed(_ name: String, _ body: () -> Void) {
        let start = CACurrentMediaTime()
        body()
        calls.append((name, Span(start: start, end: CACurrentMediaTime())))
    }
    for trial in 1...trials {
        var ids = [UInt32(target.windowNumber)]
        kosmos_add_windows(space, &ids, 1, false)
        // Alternating sizes, so each trial frames the window, as a pooled one is framed anew.
        let frame = trial.isMultiple(of: 2) ? screen.frame : screen.frame.insetBy(dx: 1, dy: 1)
        timed("frame") { ready.window.setFrame(frame, display: false) }
        timed("order below") { ready.window.order(.below, relativeTo: target.windowNumber) }
        pumpEvents(0.1)
        kosmos_remove_windows(space, &ids, 1)
        timed("order out") { ready.window.orderOut(nil) }
        pumpEvents(0.1)
        // As Kosmos makes a border window for a display with none in its pool.
        timed("make") {
            let made = ProbeBorder()
            made.window.orderFrontRegardless()
            made.window.orderOut(nil)
        }
        pumpEvents(0.05)
    }
    timed("CATransaction.lock() 5 ms") {
        CATransaction.lock()
        usleep(5000)
        CATransaction.unlock()
    }
    pumpEvents(0.05)
    running.store(false, ordering: .relaxed)
    pumpEvents(0.05)

    let both = rings.withLock { $0 }
    let spans = both.map(\.ring), locks = both.map(\.lock)
    print("built-in display, \(trials) trials\(busy ? ", WindowServer kept busy" : ""), \(spans.count) ring transactions, "
          + String(format: "%.3f ms at the median, %.3f at p99, %.3f at most; the wait for the lock before each %.3f, %.3f and %.3f ms",
                   percentile(spans.map(\.ms), 0.5), percentile(spans.map(\.ms), 0.99), spans.map(\.ms).max() ?? 0,
                   percentile(locks.map(\.ms), 0.5), percentile(locks.map(\.ms), 0.99), locks.map(\.ms).max() ?? 0))
    for name in ["frame", "order below", "order out", "make", "CATransaction.lock() 5 ms"] {
        let own = calls.filter { $0.name == name }
        let times = own.map(\.span.ms)
        let during = own.map { call in spans.filter { $0.overlaps(call.span) }.map(\.ms).max() ?? 0 }
        let waits = own.map { call in locks.filter { $0.overlaps(call.span) }.map(\.ms).max() ?? 0 }
        print(String(format: "  %@: %d calls, %.3f ms at the median, %.3f at most; under way during each, the longest ring transaction %.3f ms at the median and %.3f at most, the longest wait for the lock %.3f and %.3f",
                     name, own.count, percentile(times, 0.5), times.max() ?? 0, percentile(during, 0.5), during.max() ?? 0,
                     percentile(waits, 0.5), waits.max() ?? 0))
    }
    let slow = calls.filter { $0.span.ms > 1 && !$0.name.hasPrefix("CATransaction") }
    let during = slow.map { call in spans.filter { $0.overlaps(call.span) }.map(\.ms).max() ?? 0 }
    let waits = slow.map { call in locks.filter { $0.overlaps(call.span) }.map(\.ms).max() ?? 0 }
    print(String(format: "  AppKit calls over 1 ms: %d, up to %.3f ms; under way during them, the longest ring transaction %.3f ms, the longest wait for the lock %.3f ms",
                 slow.count, slow.map(\.span.ms).max() ?? 0, during.max() ?? 0, waits.max() ?? 0))
    kosmos_space_destroy(space)
    for window in [ready.window, sliding.window, target] { window.orderOut(nil) }
    exit(0)
}
