// What Kosmos's border windows need from macOS 27, and what they cost (docs/borders.md).
//
//   kosmos-probe borders            A border window set up as Kosmos's, around windows of a
//                                   child app: how it stacks, raises, hit tests and joins
//                                   Spaces, each target's corner radius, and what reading the
//                                   radii costs.
//   kosmos-probe border-space       Where a border window lands when it moves, ordered out,
//                                   to a Space its display does not show, as Kosmos moves one
//                                   over a native fullscreen Space, with its frame set before
//                                   or after the move, and whether it was ordered in before.
//                                   Only the probe's windows, on the built-in display or the
//                                   leftmost one, which needs a second ordinary Space.
//   kosmos-probe borders-cpu [relayouts]
//                                   The CPU of the probe, the child, WindowServer and
//                                   JankyBorders, if it runs, over 12 relayouts of four windows
//                                   by default: with no border of the probe's, with borders
//                                   following change events, and with borders stepped as a
//                                   slide steps them.
import AppKit
import CKosmos
import KosmosCore
import KosmosSkyLight

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

@MainActor func builtInScreen() -> NSScreen {
    NSScreen.screens.first { CGDisplayIsBuiltin($0.displayID) != 0 } ?? NSScreen.main ?? NSScreen.screens[0]
}

/// The second of the two layouts changes each column's width and each row's height, so every
/// window moves and resizes.
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

/// Titled windows at the bottom left of the built-in display, in an app never activated.
/// Prints their ids. On stdin, `front <id>` orders a window front, and `layout <n>` moves
/// every window to layout n and prints `done`.
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
                    } else if words.count == 6, words[0] == "frame", let id = Int(words[1]) {
                        let n = words.dropFirst(2).compactMap { Double($0) }
                        windows.first { $0.windowNumber == id }?.setFrame(NSRect(x: n[0], y: n[1], width: n[2], height: n[3]), display: true)
                        print("done")
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

/// Set up as Kosmos's border windows are (docs/borders.md).
@MainActor final class ProbeBorder {
    let window: NSWindow
    let ring = CALayer()

    init(at origin: NSPoint = .zero) {
        window = NSWindow(contentRect: NSRect(origin: origin, size: NSSize(width: 10, height: 10)), styleMask: [.borderless],
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
        ring.borderWidth = width / 2
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
    let targets = Child(["border-targets", "2"])
    let windows = targets.readWindows()
    let (t, c) = (windows[0], windows[1])
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
    WindowServerEvent.register([806, 807, 808, 815, 816]) { id, window, _ in
        guard let window else { return }
        DispatchQueue.main.async { stepEvents.append((id, window)) }
    }
    SkyLight.watch([t, c])
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

    // Hit test 1 pt outside T's left edge, under the ring.
    let hit = UInt32(NSWindow.windowNumber(at: NSPoint(x: frame.minX - 1, y: frame.midY), belowWindowWithWindowNumber: 0))
    print("hit test outside T under the ring: \(hit == b ? "B" : hit == t ? "T" : String(hit))")

    // Spaces as the border is ordered out and in.
    func spaces(_ window: UInt32) -> [UInt64] { SkyLight.spaces(of: window) ?? [] }
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

    // 50,000 radii reads that release the array and 50,000 that do not: the resident size
    // grows with the second only if the caller owns the array.
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

/// T, a window of the probe's, sits in S, an ordinary Space its display does not show. Each
/// case makes a border at the display's bottom left corner, runs its steps, orders the border
/// above T as Kosmos does, and reads the border's Spaces at once and 0.1 s later.
@MainActor func borderSpace() -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    func wait(_ seconds: Double) { pumpEvents(seconds) }
    func spaces(_ window: NSWindow) -> [UInt64] { SkyLight.spaces(of: UInt32(window.windowNumber)) ?? [] }
    func move(_ window: NSWindow, to space: UInt64) {
        SLSMoveWindowsToManagedSpace(SLSMainConnectionID(), [UInt32(window.windowNumber)] as CFArray, space)
    }

    let displays = Displays.current()
    let leftmost = NSScreen.screens.min { $0.frame.minX < $1.frame.minX }
    let candidates = [builtInScreen()] + (leftmost.map { [$0] } ?? [])
    var chosen: (screen: NSScreen, current: UInt64, other: UInt64)?
    for screen in candidates {
        let bounds = CGDisplayBounds(screen.displayID)
        let current = displays.currentSpace(at: CGPoint(x: bounds.midX, y: bounds.midY))
        let ordinary = displays.ordinarySpaces(on: screen.displayID)
        print("display \(screen.displayID) '\(screen.localizedName)': ordinary Spaces \(ordinary), current \(current.map(String.init) ?? "not ordinary")")
        if chosen == nil, let current, let other = ordinary.first(where: { $0 != current }) { chosen = (screen, current, other) }
    }
    guard let (screen, current, other) = chosen else {
        print("neither the built-in display nor the leftmost one has an ordinary Space it does not show")
        exit(0)
    }
    print("S is \(other); the display shows \(current)")

    let area = screen.visibleFrame
    let t = NSWindow(contentRect: NSRect(x: area.minX + 16, y: area.minY + 16, width: 200, height: 130), styleMask: [.titled],
                     backing: .buffered, defer: false)
    t.title = "kosmos-probe border-space T"
    t.isReleasedWhenClosed = false
    t.orderFrontRegardless()
    wait(0.1)
    move(t, to: other)
    wait(0.1)
    print("T in \(spaces(t))")

    enum Step { case prime, frame, move, pause }
    let color = CGColor(srgbRed: 0x7a / 255, green: 0xa2 / 255, blue: 0xf7 / 255, alpha: 1)
    func run(_ steps: [Step], then after: [Step] = []) {
        let border = ProbeBorder(at: screen.frame.origin)
        var offset: CGFloat = 0
        func perform(_ step: Step) {
            switch step {
            // As Kosmos makes a border window: ordered in and out back to back.
            case .prime:
                border.window.orderFrontRegardless()
                border.window.orderOut(nil)
            case .frame:
                border.place(around: t.frame.offsetBy(dx: offset, dy: 0), radius: 16, color: color)
                offset += 10
            case .move: move(border.window, to: other)
            case .pause: wait(0.1)
            }
        }
        steps.forEach(perform)
        border.window.order(.above, relativeTo: t.windowNumber)
        let atOnce = spaces(border.window)
        wait(0.1)
        let later = spaces(border.window)
        after.forEach(perform)
        if !after.isEmpty { wait(0.1) }
        let names: (Step) -> String = { step in
            switch step {
            case .prime: "ordered in and out"
            case .frame: "framed"
            case .move: "moved to S"
            case .pause: "0.1 s"
            }
        }
        let label = steps.map(names).joined(separator: ", ") + ", ordered above T"
            + (after.isEmpty ? "" : ", then " + after.map(names).joined(separator: ", "))
        func verdict(_ read: [UInt64]) -> String { read == [other] ? "in S" : read == [current] ? "in the Space shown" : "\(read)" }
        print("\(label): at once \(verdict(atOnce)), 0.1 s later \(verdict(later))"
              + (after.isEmpty ? "" : ", after \(verdict(spaces(border.window)))"))
        border.window.orderOut(nil)
        border.window.close()
    }
    run([.prime, .frame, .move])
    run([.prime, .frame, .pause, .move])
    run([.prime, .move, .frame])
    run([.prime, .move, .pause, .frame])
    run([.prime, .move])
    run([.frame, .move])
    run([.move, .frame])
    run([.move])
    run([.prime, .move], then: [.frame])
    t.orderOut(nil)
    exit(0)
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
    let targets = Child(["border-targets", "4"])
    let windows = targets.readWindows()
    let windowServer = pid("WindowServer"), janky = pid("borders")
    let color = CGColor(srgbRed: 0x7a / 255, green: 0xa2 / 255, blue: 0xf7 / 255, alpha: 1)
    let interval = 0.5
    print("\(relayouts) relayouts of 4 windows, \(interval) s apart; JankyBorders \(janky.map { "runs, pid \($0)" } ?? "is not running")")
    wait(0.5)

    let rows = Dictionary(SkyLight.rows(windows, cornerRadii: true).map { ($0.id, $0) }) { first, _ in first }
    let radii = rows.mapValues(\.cornerRadius)
    let borders = Dictionary(uniqueKeysWithValues: windows.map { ($0, ProbeBorder()) })
    let follower = Follower(borders: borders, radii: radii, color: color)
    Follower.current = follower
    // Move and resize events for the child's windows, on the probe's own connection.
    WindowServerEvent.register([806, 807]) { _, window, _ in
        guard let window else { return }
        DispatchQueue.main.async { MainActor.assumeIsolated { Follower.current?.heard(window) } }
    }
    SkyLight.watch(windows)

    struct Reading { var probe = 0.0, child = 0.0, windowServer = 0.0, janky = 0.0 }
    func read() -> Reading {
        Reading(probe: rusageCPU(getpid()) ?? 0, child: rusageCPU(targets.pid) ?? 0,
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
                for (id, frame) in zip(windows, next) {
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
    for row in SkyLight.rows(windows) {
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
