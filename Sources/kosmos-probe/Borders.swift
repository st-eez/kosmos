// What Kosmos's border windows (docs/borders.md) need from macOS 27, and what they cost.
//
//   kosmos-probe borders            A border window of the probe's own, set up as Kosmos's
//                                   are, around windows of a child app: whether ordering it
//                                   above another app's window with NSWindow.order(_:relativeTo:)
//                                   puts it directly above, what a raise of either window
//                                   does, whether WindowServer's hit test passes through it,
//                                   which Spaces it joins as it is ordered in and out, each
//                                   target's corner radius, whether the radii read returns an
//                                   array the caller owns, and what it adds to a read of rows.
//   kosmos-probe borders-cpu [relayouts]
//                                   The CPU of borders that follow relayouts of four windows
//                                   of a child app, 12 relayouts by default, against the same
//                                   relayouts with no border of the probe's: the borders
//                                   following WindowServer's change events, as Kosmos's
//                                   follow its inventory, and the borders stepped at each
//                                   display frame over 0.38 s, as a slide steps them. Reads
//                                   the CPU of the probe, the child, WindowServer and
//                                   JankyBorders if it runs, whose borders then follow the
//                                   same windows.
//   kosmos-probe border-targets <count>
//                                   The child: count titled windows in a grid at the bottom
//                                   left of the built-in display, in an accessory app, which
//                                   a running Kosmos leaves alone, never activated. Prints
//                                   their ids. Lines on stdin: `front <id>` orders a window
//                                   front, `layout <n>` moves every window to layout n of
//                                   two and prints `done`. Quits at the end of stdin.
import AppKit
import CKosmos
import KosmosCore
import KosmosSkyLight

/// The built-in display, else the main one.
@MainActor func builtInScreen() -> NSScreen {
    NSScreen.screens.first { screen in
        let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        return CGDisplayIsBuiltin(id) != 0
    } ?? NSScreen.main ?? NSScreen.screens[0]
}

/// Layout `n` of two for `count` windows at the bottom left of `area`, in AppKit's
/// coordinates: a grid of 200 by 130 point windows, and the same grid with each column's
/// width and each row's height changed, so every window moves and resizes.
func targetLayout(_ n: Int, count: Int, in area: NSRect) -> [NSRect] {
    (0..<count).map { index in
        let column = CGFloat(index % 2), row = CGFloat(index / 2)
        let origin = NSPoint(x: area.minX + 16, y: area.minY + 16)
        if n % 2 == 0 {
            return NSRect(x: origin.x + column * 212, y: origin.y + row * 142, width: 200, height: 130)
        }
        let width: CGFloat = column == 0 ? 260 : 140, height: CGFloat = row == 0 ? 100 : 160
        return NSRect(x: origin.x + (column == 0 ? 0 : 272), y: origin.y + (row == 0 ? 0 : 112), width: width, height: height)
    }
}

@MainActor func borderTargets(_ count: Int) -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let area = builtInScreen().visibleFrame
    let windows = targetLayout(0, count: count, in: area).enumerated().map { index, frame in
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "kosmos-probe border \(index + 1)"
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        return window
    }
    print(windows.map { String($0.windowNumber) }.joined(separator: " "))
    Thread.detachNewThread {
        while let line = readLine() {
            let words = line.split(separator: " ")
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if words.count == 2, words[0] == "front", let id = Int(words[1]) {
                        windows.first { $0.windowNumber == id }?.orderFrontRegardless()
                    } else if words.count == 2, words[0] == "layout", let n = Int(words[1]) {
                        for (window, frame) in zip(windows, targetLayout(n, count: windows.count, in: area)) {
                            window.setFrame(frame, display: true)
                        }
                        print("done")
                    }
                }
            }
        }
        exit(0)
    }
    app.run()
    exit(0)
}

/// A child app's windows, driven through its standard input.
final class BorderTargets {
    let process = Process()
    private(set) var windows: [UInt32] = []
    private let input = Pipe(), output = Pipe()
    private var buffer = Data()

    init(_ count: Int) {
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["border-targets", String(count)]
        process.standardInput = input
        process.standardOutput = output
        try! process.run()
        windows = line().split(separator: " ").compactMap { UInt32($0) }
    }

    func line() -> String {
        while !buffer.contains(UInt8(ascii: "\n")) {
            let chunk = output.fileHandleForReading.availableData
            guard !chunk.isEmpty else { print("targets exited"); exit(1) }
            buffer.append(chunk)
        }
        let end = buffer.firstIndex(of: UInt8(ascii: "\n"))!
        let text = String(decoding: buffer[buffer.startIndex..<end], as: UTF8.self)
        buffer.removeSubrange(buffer.startIndex...end)
        return text
    }

    func send(_ text: String) { input.fileHandleForWriting.write(Data((text + "\n").utf8)) }

    func quit() {
        try? input.fileHandleForWriting.close()
        process.waitUntilExit()
    }
}

/// A border window as Kosmos makes one: borderless, clear, click-through, out of the window
/// cycle and Mission Control, and never key. The ring is a layer's border, `width / 2 + 1`
/// wide, from half the width outside the target's frame to 1 point inside it, its corners
/// concentric with the target's.
@MainActor final class ProbeBorder {
    let window: NSWindow
    let ring = CALayer()

    init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless],
                          backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.transient, .ignoresCycle]
        let view = NSView()
        view.wantsLayer = true
        window.contentView = view
        ring.actions = ["bounds": NSNull(), "position": NSNull(), "borderColor": NSNull(), "cornerRadius": NSNull(), "borderWidth": NSNull()]
        view.layer!.addSublayer(ring)
    }

    var id: UInt32 { UInt32(window.windowNumber) }

    /// Puts the ring around `target`, in AppKit's screen coordinates.
    func place(around target: NSRect, radius: CGFloat, width: CGFloat = 4, color: CGColor) {
        let outer = target.insetBy(dx: -width / 2, dy: -width / 2)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        window.setFrame(outer, display: false)
        ring.frame = CGRect(origin: .zero, size: outer.size)
        ring.cornerRadius = radius + width / 2
        ring.borderWidth = width / 2 + 1
        ring.borderColor = color
        CATransaction.commit()
    }
}

/// AppKit's rectangle for a frame with the origin at the top left of the main display.
@MainActor func appKitRect(_ frame: CGRect) -> NSRect {
    NSRect(x: frame.minX, y: NSScreen.screens[0].frame.height - frame.maxY, width: frame.width, height: frame.height)
}

/// Runs the app's event loop for `seconds`, which delivers SkyLight's notifications too.
@MainActor func pumpEvents(_ seconds: Double) {
    let deadline = Date(timeIntervalSinceNow: seconds)
    while let event = NSApp.nextEvent(matching: .any, until: deadline, inMode: .default, dequeue: true) {
        NSApp.sendEvent(event)
    }
}

@MainActor func borders() -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    func wait(_ seconds: Double) { pumpEvents(seconds) }
    let targets = BorderTargets(2)
    let (t, c) = (targets.windows[0], targets.windows[1])
    wait(0.3)
    let jankyPID = NSWorkspace.shared.runningApplications.first { $0.executableURL?.lastPathComponent == "borders" }?.processIdentifier
    func name(_ window: UInt32, _ pid: pid_t, _ border: UInt32) -> String {
        switch window {
        case t: "T (target)"
        case c: "C (cover)"
        case border: "B (border)"
        default: pid == jankyPID ? "JankyBorders \(window)" : pid == getpid() ? "probe \(window)" : "\(window) of pid \(pid)"
        }
    }
    /// The windows on screen from T's neighbours up: the probe's, the child's and any
    /// JankyBorders window within them, front to back.
    func stacking(_ label: String, border: UInt32) {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let rows = list.compactMap { info -> (id: UInt32, pid: pid_t, layer: Int)? in
            guard let id = info[kCGWindowNumber as String] as? UInt32, let pid = info[kCGWindowOwnerPID as String] as? pid_t else { return nil }
            return (id, pid, info[kCGWindowLayer as String] as? Int ?? 0)
        }
        let ours = rows.indices.filter { [t, c, border].contains(rows[$0].id) }
        guard let first = ours.min(), let last = ours.max() else { return print("\(label): none of the windows is on screen") }
        let shown = rows[max(0, first - 1)...min(rows.count - 1, last + 1)].map { "\(name($0.id, $0.pid, border)) at layer \($0.layer)" }
        print("\(label), front to back: \(shown.joined(separator: ", "))")
    }

    // Rows and corner radii of the child's titled windows, and what reading the radii adds
    // to a read of the rows, the two reads alternating.
    let rows = Dictionary(SkyLight.rows([t, c], cornerRadii: true).map { ($0.id, $0) }) { first, _ in first }
    let radius = rows[t]?.cornerRadius ?? 0
    for id in [t, c] {
        print("\(id == t ? "T" : "C"): level \(rows[id]?.level ?? -1), frame \(rows[id].map { String(describing: $0.frame) } ?? "?"), corner radius \(rows[id]?.cornerRadius ?? -1)")
    }
    var plain: [Double] = [], withRadii: [Double] = []
    for _ in 0..<5000 {
        var start = ContinuousClock.now
        _ = SkyLight.rows([t, c])
        plain.append(elapsed(start))
        start = .now
        _ = SkyLight.rows([t, c], cornerRadii: true)
        withRadii.append(elapsed(start))
    }
    print(String(format: "rows of 2 windows: %.4f ms median, with the corner radii %.4f ms median",
                 percentile(plain, 0.5), percentile(withRadii, 0.5)))

    // The events WindowServer sends for T and C at each step: moved (806), resized (807),
    // reordered (808), ordered in (815) and out (816).
    stepEvents = []
    for id: UInt32 in [806, 807, 808, 815, 816] {
        SLSRegisterConnectionNotifyProc(SLSMainConnectionID(), { id, data, length, _, _ in
            guard let data, length >= 4 else { return }
            let window = data.loadUnaligned(as: UInt32.self)
            DispatchQueue.main.async { stepEvents.append((id, window)) }
        }, id, nil)
    }
    var watched = [t, c]
    SLSRequestNotificationsForWindows(SLSMainConnectionID(), &watched, 2)
    func events() -> String {
        defer { stepEvents = [] }
        return stepEvents.isEmpty ? "no events" : "events " + stepEvents.map { "\($0.id) for \($0.window == t ? "T" : $0.window == c ? "C" : String($0.window))" }.joined(separator: ", ")
    }

    // The border, ordered directly above T.
    let border = ProbeBorder()
    let frame = appKitRect(rows[t]!.frame)
    let color = CGColor(srgbRed: 0x7a / 255, green: 0xa2 / 255, blue: 0xf7 / 255, alpha: 1)
    var start = ContinuousClock.now
    border.place(around: frame, radius: radius, color: color)
    let placed = elapsed(start)
    start = .now
    border.window.order(.above, relativeTo: Int(t))
    print(String(format: "place %.3f ms, order above T %.3f ms", placed, elapsed(start)))
    wait(0.2)
    let b = border.id
    stacking("ordered above T", border: b)
    print("  \(events())")
    targets.send("front \(c)")
    wait(0.2)
    stacking("after the child orders C front", border: b)
    print("  \(events())")
    targets.send("front \(t)")
    wait(0.2)
    stacking("after the child orders T front", border: b)
    print("  \(events())")
    border.window.order(.above, relativeTo: Int(t))
    wait(0.2)
    stacking("B ordered above T again", border: b)
    print("  \(events())")
    var orders: [Double] = []
    for _ in 0..<100 {
        start = .now
        border.window.order(.above, relativeTo: Int(t))
        orders.append(elapsed(start))
    }
    wait(0.2)
    print(String(format: "100 more orders above T: %.3f ms median, %.3f ms at most; ", percentile(orders, 0.5), orders.max()!) + events())

    // Hit tests: 0.5 pt inside T's left edge, under the ring's inner point, and 1 pt
    // outside it, under the ring alone.
    let inside = NSPoint(x: frame.minX + 0.5, y: frame.midY), outside = NSPoint(x: frame.minX - 1, y: frame.midY)
    for (label, point) in [("inside T under the ring", inside), ("outside T under the ring", outside)] {
        let hit = UInt32(NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0))
        print("hit test \(label): \(hit == b ? "B" : hit == t ? "T" : String(hit))")
    }

    // Spaces as the border is ordered out and in.
    func spaces(_ window: UInt32) -> [UInt64] { kosmos_window_spaces(window) as? [UInt64] ?? [] }
    print("T's Spaces \(spaces(t)); B's ordered in \(spaces(b))")
    border.window.orderOut(nil)
    wait(0.1)
    print("B's ordered out \(spaces(b))")
    border.window.order(.above, relativeTo: Int(t))
    wait(0.1)
    print("B's ordered in again \(spaces(b))")

    // Whether a border moved to another display's Space comes back to T's when it is ordered
    // above T. The border stays at the bottom left of the built-in display, so nothing shows
    // on the other display.
    if let other = Displays.current().displays.compactMap(\.currentSpace).first(where: { !spaces(t).contains($0) }) {
        SLSMoveWindowsToManagedSpace(SLSMainConnectionID(), [b] as CFArray, other)
        wait(0.1)
        print("B moved to another display's Space \(other): \(spaces(b))")
        border.window.order(.above, relativeTo: Int(t))
        wait(0.1)
        print("then ordered above T: \(spaces(b))")
        border.window.orderOut(nil)
        border.window.order(.above, relativeTo: Int(t))
        wait(0.1)
        print("then ordered out and above T again: \(spaces(b))")
        border.place(around: frame.offsetBy(dx: 10, dy: 0), radius: radius, color: color)
        wait(0.1)
        print("then moved 10 pt: \(spaces(b))")
        SLSMoveWindowsToManagedSpace(SLSMainConnectionID(), [b] as CFArray, spaces(t).first ?? 0)
        wait(0.1)
        print("moved back to T's Space: \(spaces(b))")
    } else {
        print("no other display's Space to move B to")
    }

    // Who owns the radii array: 50,000 reads that release it and 50,000 that do not, with the
    // resident size after each. The size grows only when the reads keep them, so the caller
    // owns the array, as JankyBorders's CFRelease of it assumes.
    func resident() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        _ = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        return Double(info.resident_size) / 1_048_576
    }
    func radiiReads(release: Bool) {
        guard let query = SLSWindowQueryWindows(SLSMainConnectionID(), [t] as CFArray, 1),
              let iterator = SLSWindowQueryResultCopyWindows(query.takeUnretainedValue()) else { return }
        let it = iterator.takeUnretainedValue()
        _ = SLSWindowIteratorAdvance(it)
        for _ in 0..<50_000 {
            autoreleasepool {
                guard let radii = SLSWindowIteratorGetCornerRadii(it) else { return }
                if release { radii.release() }
            }
        }
        iterator.release()
        query.release()
    }
    let before = resident()
    radiiReads(release: true)
    let released = resident()
    radiiReads(release: false)
    print(String(format: "resident %.1f MB, after 50,000 reads released %.1f MB, after 50,000 kept %.1f MB", before, released, resident()))

    // What a step costs on the main thread, 200 of each: the window resized, the window
    // moved at its size, and the ring's layer moved and resized in a window that stays.
    func time(_ label: String, _ step: (Int) -> Void) {
        var times: [Double] = []
        let cpu = rusageCPU(getpid()) ?? 0
        for index in 0..<200 {
            let start = ContinuousClock.now
            step(index)
            times.append(elapsed(start))
        }
        print(String(format: "%@: %.3f ms median, %.3f ms p90, %.3f ms CPU each", label, percentile(times, 0.5), percentile(times, 0.9),
                     ((rusageCPU(getpid()) ?? 0) - cpu) / 200))
    }
    time("window resized") { index in
        border.place(around: frame.insetBy(dx: CGFloat(index % 20), dy: CGFloat(index % 20)), radius: 16, color: color)
    }
    time("window moved") { index in
        border.window.setFrameOrigin(NSPoint(x: frame.minX - 2 + CGFloat(index % 20), y: frame.minY - 2))
    }
    border.place(around: frame.insetBy(dx: -40, dy: -40), radius: 16, color: color)
    time("layer moved and resized") { index in
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        border.ring.frame = CGRect(x: CGFloat(index % 20), y: CGFloat(index % 20), width: frame.width + 4 - CGFloat(index % 20),
                                   height: frame.height + 4 - CGFloat(index % 20))
        CATransaction.commit()
    }
    border.place(around: frame, radius: radius, color: color)

    // What a large border costs in memory: the probe's footprint before and after a border
    // around 1200 by 800 points at the bottom left of the built-in display.
    func footprint() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        _ = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return Double(info.phys_footprint) / 1_048_576
    }
    let small = footprint()
    let area = builtInScreen().visibleFrame
    let large = ProbeBorder()
    large.place(around: NSRect(x: area.minX + 8, y: area.minY + 8, width: 1200, height: 800), radius: 16, color: color)
    large.window.orderFrontRegardless()
    wait(0.5)
    let shown = footprint()
    large.window.orderOut(nil)
    wait(0.5)
    print(String(format: "footprint %.1f MB, with a 1200 by 800 border shown %.1f MB, ordered out %.1f MB", small, shown, footprint()))

    border.window.orderOut(nil)
    targets.quit()
    exit(0)
}

/// Steps borders along slides at each display frame. `inPlace`: each border's window covers
/// its whole slide from the start, and only the ring's layer moves at each step.
@MainActor private final class SlideStepper: NSObject {
    var slides: [(border: ProbeBorder, slide: Slide, radius: CGFloat)] = []
    var link: CADisplayLink?
    var steps = 0
    var stepTime = 0.0
    let color: CGColor
    let inPlace: Bool

    init(color: CGColor, inPlace: Bool) {
        self.color = color
        self.inPlace = inPlace
    }

    func add(_ border: ProbeBorder, _ slide: Slide, radius: CGFloat) {
        slides.append((border, slide, radius))
        guard inPlace else { return }
        let area = appKitRect(slide.from.union(slide.to)).insetBy(dx: -2, dy: -2)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        border.window.setFrame(area, display: false)
        CATransaction.commit()
    }

    func start() {
        guard link == nil else { return }
        let screen = NSScreen.screens.max { $0.maximumFramesPerSecond < $1.maximumFramesPerSecond }!
        let link = screen.displayLink(target: self, selector: #selector(frame))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc func frame(_ link: CADisplayLink) {
        let began = CACurrentMediaTime()
        for entry in slides {
            let shown = appKitRect(entry.slide.shown(at: link.targetTimestamp).frame)
            if inPlace {
                let origin = entry.border.window.frame.origin
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                entry.border.ring.frame = shown.insetBy(dx: -2, dy: -2).offsetBy(dx: -origin.x, dy: -origin.y)
                CATransaction.commit()
            } else {
                entry.border.place(around: shown, radius: entry.radius, color: color)
            }
            steps += 1
        }
        for entry in slides where inPlace && entry.slide.isOver(at: link.targetTimestamp) {
            entry.border.place(around: appKitRect(entry.slide.to), radius: entry.radius, color: color)
        }
        slides.removeAll { $0.slide.isOver(at: link.targetTimestamp) }
        stepTime += CACurrentMediaTime() - began
        if slides.isEmpty {
            link.invalidate()
            self.link = nil
        }
    }
}

nonisolated(unsafe) var stepEvents: [(id: UInt32, window: UInt32)] = []

/// Moves the borders after WindowServer's change events, as Kosmos does: the events of one
/// run loop turn, one read of their rows, and each border placed at its window's frame.
@MainActor final class Follower {
    static var current: Follower?
    var on = false
    var updates = 0, updateTime = 0.0
    private var pending: Set<UInt32> = []
    private let borders: [UInt32: ProbeBorder]
    private let radii: [UInt32: CGFloat]
    private let color: CGColor

    init(borders: [UInt32: ProbeBorder], radii: [UInt32: CGFloat], color: CGColor) {
        self.borders = borders
        self.radii = radii
        self.color = color
    }

    func heard(_ window: UInt32) {
        guard on else { return }
        if pending.isEmpty { DispatchQueue.main.async { MainActor.assumeIsolated { self.flush() } } }
        pending.insert(window)
    }

    private func flush() {
        let began = CACurrentMediaTime()
        for row in SkyLight.rows(Array(pending)) {
            borders[row.id]?.place(around: appKitRect(row.frame), radius: radii[row.id] ?? 0, color: color)
        }
        pending = []
        updateTime += CACurrentMediaTime() - began
        updates += 1
    }
}

@MainActor func bordersCPU(relayouts: Int) -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.finishLaunching()
    func wait(_ seconds: Double) { pumpEvents(seconds) }
    func pid(_ name: String) -> pid_t? {
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-x", name]
        let pipe = Pipe()
        pgrep.standardOutput = pipe
        try? pgrep.run()
        pgrep.waitUntilExit()
        return pid_t(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n").first ?? "")
    }
    let targets = BorderTargets(4)
    let windowServer = pid("WindowServer"), janky = pid("borders")
    let color = CGColor(srgbRed: 0x7a / 255, green: 0xa2 / 255, blue: 0xf7 / 255, alpha: 1)
    let interval = 0.5
    print("\(relayouts) relayouts of 4 windows, \(interval) s apart; JankyBorders \(janky.map { "runs, pid \($0)" } ?? "is not running")")
    wait(0.5)

    let rows = Dictionary(SkyLight.rows(targets.windows, cornerRadii: true).map { ($0.id, $0) }) { first, _ in first }
    let radii = rows.mapValues(\.cornerRadius)
    let borders = Dictionary(uniqueKeysWithValues: targets.windows.map { ($0, ProbeBorder()) })
    let follower = Follower(borders: borders, radii: radii, color: color)
    Follower.current = follower
    // Move and resize events for the child's windows, on the probe's own connection.
    for id: UInt32 in [806, 807] {
        SLSRegisterConnectionNotifyProc(SLSMainConnectionID(), { _, data, length, _, _ in
            guard let data, length >= 4 else { return }
            let window = data.loadUnaligned(as: UInt32.self)
            DispatchQueue.main.async { MainActor.assumeIsolated { Follower.current?.heard(window) } }
        }, id, nil)
    }
    var watched = targets.windows
    SLSRequestNotificationsForWindows(SLSMainConnectionID(), &watched, Int32(watched.count))

    struct Reading { var probe = 0.0, child = 0.0, windowServer = 0.0, janky = 0.0 }
    func read() -> Reading {
        Reading(probe: rusageCPU(getpid()) ?? 0, child: rusageCPU(targets.process.processIdentifier) ?? 0,
                windowServer: windowServer.flatMap(psCPU) ?? 0, janky: janky.flatMap(rusageCPU) ?? 0)
    }
    func each(_ a: Double, _ b: Double) -> String { String(format: "%6.2f", (b - a) / Double(relayouts)) }
    var layout = 0
    /// Runs the relayouts, the borders following each change event while the follower is on,
    /// or stepped by `slide`, and prints the CPU each process spent per relayout.
    func run(_ mode: String, slide: SlideStepper? = nil) {
        let before = read()
        let started = ContinuousClock.now
        for _ in 0..<relayouts {
            layout += 1
            if let slide {
                // The border slides from where it shows to the new frame, as the window would.
                let next = targetLayout(layout, count: 4, in: builtInScreen().visibleFrame)
                let top = NSScreen.screens[0].frame.height
                func flipped(_ rect: NSRect) -> CGRect { CGRect(x: rect.minX, y: top - rect.maxY, width: rect.width, height: rect.height) }
                for (id, frame) in zip(targets.windows, next) {
                    let border = borders[id]!
                    let from = border.window.frame.insetBy(dx: 2, dy: 2)
                    slide.add(border, .move(from: flipped(from), to: flipped(frame), at: CACurrentMediaTime()),
                              radius: radii[id] ?? 0)
                }
                slide.start()
            }
            targets.send("layout \(layout)")
            _ = targets.line()
            wait(interval)
        }
        let after = read(), seconds = elapsed(started) / 1000
        print("\(mode.padding(toLength: 34, withPad: " ", startingAt: 0)) ms CPU per relayout: probe \(each(before.probe, after.probe)), " +
              "child \(each(before.child, after.child)), WindowServer \(each(before.windowServer, after.windowServer)), " +
              "JankyBorders \(janky == nil ? "-" : each(before.janky, after.janky)) (\(String(format: "%.1f", seconds)) s)")
    }

    // Rest, for the baseline of each process over the same time.
    let rest = read()
    wait(Double(relayouts) * interval)
    let rested = read()
    print("\("rest, per relayout's time".padding(toLength: 34, withPad: " ", startingAt: 0)) ms CPU: probe \(each(rest.probe, rested.probe)), " +
          "child \(each(rest.child, rested.child)), WindowServer \(each(rest.windowServer, rested.windowServer)), " +
          "JankyBorders \(janky == nil ? "-" : each(rest.janky, rested.janky))")
    run("relayouts, no border of the probe's")
    for (id, border) in borders {
        border.place(around: appKitRect(rows[id]!.frame), radius: radii[id] ?? 0, color: color)
        border.window.order(.above, relativeTo: Int(id))
    }
    // Where the windows are now.
    for row in SkyLight.rows(targets.windows) {
        borders[row.id]?.place(around: appKitRect(row.frame), radius: radii[row.id] ?? 0, color: color)
    }
    follower.on = true
    run("borders follow change events")
    follower.on = false
    print(String(format: "  %d updates on the main thread, %.3f ms each on average", follower.updates,
                 follower.updateTime * 1000 / Double(max(follower.updates, 1))))
    for inPlace in [false, true] {
        let stepper = SlideStepper(color: color, inPlace: inPlace)
        run(inPlace ? "borders slide, layer steps" : "borders slide, window steps", slide: stepper)
        print(String(format: "  %d border steps, %.3f ms each on average", stepper.steps, stepper.stepTime * 1000 / Double(max(stepper.steps, 1))))
    }
    for border in borders.values { border.window.orderOut(nil) }
    targets.quit()
    exit(0)
}

/// A process's CPU time in ms, or nil when the kernel refuses to read it, as for another
/// user's process. rusage counts in mach time units.
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

/// A process's CPU time in ms as ps prints it, "minutes:seconds.hundredths", for WindowServer,
/// which runs as another user.
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
