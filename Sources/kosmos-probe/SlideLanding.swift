// When a sliding window's write lands against the transform that shows it, and how soon each
// way of following the landing sets the transform again (docs/geometry.md).
//
//   kosmos-probe slide-landing [landings] [mode...]
//                                   A red window of a child app, in an animation Space of the
//                                   probe's whose transform holds it still at the bottom left of
//                                   the built-in display, over a black window. The probe writes
//                                   the window's position through Accessibility, 240 points right
//                                   or back, at a random point of the refresh, as Kosmos writes a
//                                   sliding window, and follows each landing as the mode says. A
//                                   strip recorded with ScreenCaptureKit counts the frames that
//                                   show the window off its place. Each mode runs 16 landings by
//                                   default, or the modes named run alone:
//                                     none    follows nothing until 60 ms after the write: when
//                                             the landing shows, against the window's 806 and 807
//                                             notifications
//                                     poll    reads the window's row as Kosmos does, every 0.1 ms
//                                             within 20 ms of the write, its return or a new
//                                             frame, and every 1 ms after
//                                     spin    reads the row back to back
//                                     notify  reads the row in each 806 or 807 notification of
//                                             the window, and sets the transform there
//                                     target  sets the transform for the write's target in the
//                                             window's first 806 or 807 notification, unread
//                                   Then times 200 reads of the row against SLSGetWindowBounds.
//                                   Needs Accessibility and Screen Recording for the terminal,
//                                   and exits rather than ask. A crash leaves the Space, empty.
import AppKit
import CKosmos
import KosmosCore
import KosmosSkyLight
import Synchronization

private let landingDistance: CGFloat = 240

private enum LandingMode: String, CaseIterable, Sendable {
    case none, poll, spin, notify, target
}

/// Where the child's window rests, in CoreGraphics' coordinates, with room on both sides for
/// it to show displaced by the whole move.
@MainActor private func landingRest(_ screen: NSScreen) -> CGRect {
    let visible = appKitRect(screen.visibleFrame)
    return CGRect(x: visible.minX + 40 + landingDistance, y: visible.maxY - 160, width: 180, height: 120)
}

/// A red titled window at rest on the built-in display, in an app never activated. Prints its
/// id and runs until its standard input closes.
@MainActor func landingWindow() -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
    window.title = "kosmos-probe landing"
    window.backgroundColor = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
    window.animationBehavior = .none
    window.isReleasedWhenClosed = false
    window.setFrame(appKitRect(landingRest(builtInScreen())), display: true)
    window.orderFrontRegardless()
    print(window.windowNumber)
    Thread.detachNewThread {
        while readLine() != nil {}
        exit(0)
    }
    app.run()
    exit(0)
}

/// One write and its landing, on CACurrentMediaTime's clock.
private struct Landing: Sendable {
    let mode: LandingMode
    let to: CGRect
    let sent: Double
    var returned: Double?
    /// Each 806 or 807 for the window, and whether it came on the main thread.
    var notified: [(at: Double, main: Bool)] = []
    /// When the transform for the write's target went.
    var followed: Double?
    /// Set when nothing followed the landing by the settle.
    var settled = false
}

/// Keeps the transform that shows the window at rest, for the frame WindowServer has it at as
/// each mode learns it.
private final class LandingFollower: Sendable {
    struct State: Sendable {
        var landing: Landing?
        /// The frame the transform was last set for.
        var actual: CGRect
        var payloads: [UInt32: [UInt8]] = [:]
        /// How long each transform took to send, in ms.
        var sends: [Double] = []
    }

    let state: Mutex<State>
    private let space: UInt64, window: UInt32, rest: CGRect
    private let queue = DispatchQueue(label: "kosmos-probe.slide-landing", qos: .userInteractive)

    init(space: UInt64, window: UInt32, rest: CGRect) {
        (self.space, self.window, self.rest) = (space, window, rest)
        state = Mutex(State(actual: rest))
    }

    /// `state` comes from the lock.
    private func show(_ frame: CGRect, in state: inout State, at now: Double) -> Bool {
        guard frame != state.actual else { return false }
        state.actual = frame
        let start = CACurrentMediaTime()
        kosmos_space_set_transform(space, Slide.transform(showing: rest, at: frame))
        state.sends.append((CACurrentMediaTime() - start) * 1000)
        if frame == state.landing?.to, state.landing?.followed == nil { state.landing?.followed = now }
        return true
    }

    func begin(_ landing: Landing) {
        state.withLock { $0.landing = landing }
        guard landing.mode == .poll || landing.mode == .spin else { return }
        let spin = landing.mode == .spin
        queue.async {
            var changed = landing.sent
            while true {
                let now = CACurrentMediaTime()
                let (done, returned) = self.state.withLock { state in
                    (state.landing?.followed != nil || state.landing?.settled != false, state.landing?.returned)
                }
                if done { break }
                if let returned, returned > changed, now - returned < 0.02 { changed = returned }
                let frame = SkyLight.rows([self.window])?.first?.frame
                let read = CACurrentMediaTime()
                if let frame, self.state.withLock({ self.show(frame, in: &$0, at: read) }) { changed = read }
                if !spin { usleep(read - changed < 0.02 ? 100 : 1000) }
            }
        }
    }

    func returned(at time: Double) {
        state.withLock { $0.landing?.returned = time }
    }

    /// On the thread that read the event.
    func notified(_ id: UInt32, window: UInt32?, payload: UnsafeRawBufferPointer) {
        let now = CACurrentMediaTime(), main = pthread_main_np() != 0
        guard window == self.window else { return }
        let bytes = [UInt8](payload)
        state.withLock { state in
            if state.payloads[id] == nil { state.payloads[id] = bytes }
            guard let mode = state.landing?.mode else { return }
            state.landing?.notified.append((now, main))
            switch mode {
            case .notify:
                if let frame = SkyLight.rows([self.window])?.first?.frame { _ = show(frame, in: &state, at: CACurrentMediaTime()) }
            case .target:
                if let to = state.landing?.to { _ = show(to, in: &state, at: now) }
            case .none, .poll, .spin:
                break
            }
        }
    }

    /// Shows the window at rest again if nothing followed its landing.
    func settle() {
        state.withLock { state in
            guard let to = state.landing?.to, state.landing?.followed == nil else { return }
            state.landing?.settled = true
            _ = show(to, in: &state, at: CACurrentMediaTime())
            state.landing?.followed = nil
        }
    }

    func finish() -> Landing? {
        state.withLock { state in
            defer { state.landing = nil }
            return state.landing
        }
    }
}

/// Each display link timestamp, the vsyncs the landings are placed against.
@MainActor private final class Vsyncs: NSObject {
    private(set) var times: [Double] = []
    private var link: CADisplayLink?

    init(_ screen: NSScreen, rate: Int) {
        super.init()
        let link = screen.displayLink(target: self, selector: #selector(tick))
        let rate = Float(rate)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) { times.append(link.timestamp) }

    func stop() {
        link?.invalidate()
        link = nil
    }
}

@MainActor func slideLanding(landings count: Int, modes: [String]) -> Never {
    let named = modes.map(LandingMode.init(rawValue:))
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
    let rate = max(screen.maximumFramesPerSecond, 1), refresh = 1 / Double(rate), scale = screen.backingScaleFactor
    let bounds = CGDisplayBounds(screen.displayID)
    let rest = landingRest(screen)
    let path = rest.offsetBy(dx: -landingDistance, dy: 0).union(rest.offsetBy(dx: landingDistance, dy: 0)).insetBy(dx: -24, dy: -24)

    let backdrop = NSWindow(contentRect: appKitRect(path), styleMask: [.borderless], backing: .buffered, defer: false)
    backdrop.backgroundColor = .black
    backdrop.hasShadow = false
    backdrop.ignoresMouseEvents = true
    backdrop.animationBehavior = .none
    backdrop.isReleasedWhenClosed = false
    backdrop.collectionBehavior = [.transient, .ignoresCycle]
    backdrop.orderFrontRegardless()

    let child = Child(["landing-window"])
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
    let space = kosmos_float_space_create(1)
    guard space != 0 else {
        print("error: no animation Space")
        child.terminate()
        exit(1)
    }
    var ids = [window]
    kosmos_add_windows(space, &ids, 1, false)
    let follower = LandingFollower(space: space, window: window, rest: rest)
    WindowServerEvent.register([806, 807]) { id, named, payload in follower.notified(id, window: named, payload: payload) }
    SkyLight.watch([window])
    let vsyncs = Vsyncs(screen, rate: rate)

    // A strip 4 points tall across the path, 40 points above the window's bottom edge, in the
    // display's points from its top left. The reader gives the red's left edge in points from
    // the window's place at rest.
    let strip = CGRect(x: path.minX - bounds.minX, y: rest.maxY - 40 - bounds.minY - 2, width: path.width, height: 4)
    let capture = StripCapture(displayID: screen.displayID, strip: strip, scale: scale, rate: rate) { row, width in
        let pixels = CGFloat(width) / strip.width
        guard let first = (0..<width).first(where: { x in
            let pixel = row[x]
            return (pixel >> 16) & 0xff > 160 && (pixel >> 8) & 0xff < 100 && pixel & 0xff < 100
        }) else { return (nil, nil) }
        return (Double(path.minX + CGFloat(first) / pixels - rest.minX), nil)
    }
    capture.start()
    let started = Date()
    while capture.frames.withLock({ $0.isEmpty }), Date().timeIntervalSince(started) < 3 { pumpEvents(0.05) }
    func cleanUp() {
        capture.stop()
        vsyncs.stop()
        kosmos_remove_windows(space, &ids, 1)
        kosmos_space_destroy(space)
        backdrop.orderOut(nil)
        child.quit()
    }
    guard !capture.frames.withLock({ $0.isEmpty }) else {
        print("error: the capture sent no frame\(capture.failure.withLock { $0.map { ": \($0)" } ?? "" })")
        cleanUp()
        exit(1)
    }
    print(String(format: "built-in display at %d Hz, %.0fx; window %d of pid %d, %.0f by %.0f at (%.0f, %.0f), written %.0f points right and back",
                 rate, scale, window, child.pid, rest.width, rest.height, rest.minX, rest.minY, landingDistance))

    let writes = DispatchQueue(label: "kosmos-probe.slide-landing.writes", qos: .userInitiated)
    let chosen = named.isEmpty ? LandingMode.allCases : named.compactMap { $0 }
    var at = rest
    for mode in chosen {
        var landings: [Landing] = []
        for _ in 1...count {
            // A write at a random point of the refresh, as a relayout's is.
            pumpEvents(0.1 + Double.random(in: 0..<refresh))
            let to = at == rest ? rest.offsetBy(dx: landingDistance, dy: 0) : rest
            follower.begin(Landing(mode: mode, to: to, sent: CACurrentMediaTime()))
            writes.async {
                var origin = to.origin
                AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &origin)!)
                follower.returned(at: CACurrentMediaTime())
            }
            pumpEvents(mode == .none ? 0.06 : 0.1)
            follower.settle()
            pumpEvents(0.03)
            if let landing = follower.finish() { landings.append(landing) }
            at = to
        }
        reportLandings(mode, landings, frames: capture.frames.withLock { $0 }, vsyncs: vsyncs.times, refresh: refresh, scale: scale)
    }

    let (payloads, sends) = follower.state.withLock { ($0.payloads, $0.sends) }
    print(String(format: "%d transforms sent, each in %.3f ms at the median, %.3f at p90, %.3f at most",
                 sends.count, percentile(sends, 0.5), percentile(sends, 0.9), sends.max() ?? 0))
    for (id, bytes) in payloads.sorted(by: { $0.key < $1.key }) {
        print("event \(id): \(bytes.count) bytes, \(bytes.map { String(format: "%02x", $0) }.joined())")
    }
    var rowTimes: [Double] = [], boundsTimes: [Double] = [], agreed = 0
    for _ in 0..<200 {
        let a = CACurrentMediaTime()
        let row = SkyLight.rows([window])?.first?.frame
        let b = CACurrentMediaTime()
        var frame = CGRect.zero
        let error = SLSGetWindowBounds(SkyLight.connection, window, &frame)
        let c = CACurrentMediaTime()
        rowTimes.append((b - a) * 1000)
        boundsTimes.append((c - b) * 1000)
        if error == .success, frame == row { agreed += 1 }
    }
    print(String(format: "200 reads: the row %.3f ms at the median, %.3f at p90; SLSGetWindowBounds %.3f and %.3f, the same frame in %d",
                 percentile(rowTimes, 0.5), percentile(rowTimes, 0.9), percentile(boundsTimes, 0.5), percentile(boundsTimes, 0.9), agreed))
    cleanUp()
    exit(0)
}

/// For each landing, the frames from its write to 130 ms after that show the window off its
/// place, and when they came against its notifications.
@MainActor private func reportLandings(_ mode: LandingMode, _ landings: [Landing], frames: [Seen], vsyncs: [Double], refresh: Double,
                                       scale: CGFloat) {
    func ms(_ seconds: Double) -> String { String(format: "%.2f", seconds * 1000) }
    func median(_ values: [Double]) -> String { values.isEmpty ? "-" : ms(percentile(values, 0.5)) }
    /// How far after the vsync before it, in ms.
    func phase(_ time: Double) -> Double? {
        vsyncs.last { $0 <= time }.map { (time - $0).truncatingRemainder(dividingBy: refresh) }
    }
    var blipped = 0, offFrames = 0, onMain = 0, notices = 0, settled = 0
    var ax: [Double] = [], notice: [Double] = [], follow: [Double] = [], shown: [Double] = []
    var lines: [String] = []
    for (index, landing) in landings.enumerated() {
        let seen = frames.filter { $0.time >= landing.sent && $0.time <= landing.sent + 0.13 }
        let off = seen.filter { ($0.window.map { abs($0) } ?? .infinity) > 2 / Double(scale) }
        if !off.isEmpty { blipped += 1 }
        offFrames += off.count
        if landing.settled { settled += 1 }
        onMain += landing.notified.filter(\.main).count
        notices += landing.notified.count
        if let returned = landing.returned { ax.append(returned - landing.sent) }
        let first = landing.notified.first?.at
        if let first, let returned = landing.returned { notice.append(first - returned) }
        if let first, let followed = landing.followed { follow.append(followed - first) }
        if let first, let shownAt = off.first?.time { shown.append(shownAt - first) }
        func after(_ time: Double?) -> String { time.map { ms($0 - landing.sent) } ?? "-" }
        let places = off.map { $0.window.map { String(format: "%+.0f", $0) } ?? "gone" }.joined(separator: " ")
        lines.append("  \(index + 1): returned \(after(landing.returned)), notified \(landing.notified.map { after($0.at) }.joined(separator: " ")) "
                     + "(\(first.flatMap(phase).map(ms) ?? "-") ms after its vsync), followed \(after(landing.followed))"
                     + "\(landing.settled ? " at the settle" : ""); \(off.count) frames off"
                     + (off.isEmpty ? "" : " from \(after(off.first?.time)) to \(after(off.last?.time)), at \(places)"))
    }
    print("\(mode.rawValue): \(blipped) of \(landings.count) landings showed the window off its place, \(offFrames) frames in all; "
          + "\(settled) followed only at the settle")
    print("  ms at the median: the write \(median(ax)), its first 806 or 807 after it returned \(median(notice)), "
          + "the transform after that notification \(median(follow)), the first frame off after it \(median(shown)); "
          + "\(onMain) of \(notices) notifications on the main thread")
    print("  per landing, ms after the write:")
    lines.forEach { print($0) }
}
