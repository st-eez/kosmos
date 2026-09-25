// kosmos-probe float-layer: can Kosmos keep another app's floating windows above its tiled
// windows with SIP on? No process can set the level of another app's window, so the float
// goes into a Space of its own, shown in place (identity transform, alpha 1) at an absolute
// level above the desktop Space's. The holding Space is such a Space at level 400, moved off
// every display and transparent (DESIGN.md, sections 4.3 and 5.3).
//
// Two stub apps open 100 by 100 point windows at the bottom left of the built-in display:
// A1, the tile, and B1, the float, which overlaps it. Step 1 orders A1 front each way that
// takes no keyboard focus: AXRaise from the probe, and orderFront and orderFrontRegardless
// from A itself. It does so first with no float Space, as a control, then with B1 added to
// one, keeping its ordinary Space and exclusively, and after each reads WindowServer's hit
// test at the center of the overlap and the on-screen window order. It tries levels upward
// from the desktop Space's and stops at the first that keeps B1 on top every way.
//
// The stubs have the prohibited activation policy, so they can never be the front process
// and Kosmos leaves them alone; the probe takes no focus. The windows show for a few
// seconds. However the probe exits, Ctrl-C included, it kills the stubs, which takes their
// windows away, then destroys its Spaces; only a SIGKILL leaves the Spaces, empty. Needs
// Accessibility for the terminal; the probe never asks for it.
import AppKit
import CKosmos
import KosmosSkyLight

@MainActor func floatLayer() -> Never {
    guard AXIsProcessTrusted() else { print("this terminal needs Accessibility permission"); exit(1) }
    let app = NSApplication.shared   // bridged operations need an AppKit client
    app.setActivationPolicy(.prohibited)
    guard builtInScreen() != nil else { print("no built-in display"); exit(1) }
    installCleanup()
    let probe = FloatLayer(policy: "prohibited")
    if let found = probe.step1() {
        let ways = found.exclusive.map { $0 ? "added exclusively" : "keeping its ordinary Space" }
        print("step 1: yes. At level \(found.level), B1 stayed on top every way, \(ways.joined(separator: " and "))")
    } else {
        print("step 1: no. No level kept B1 on top every way")
    }
    probe.finish()
}

@MainActor final class FloatLayer {
    enum Raise: String, CaseIterable {
        case axRaise = "AXRaise from the probe"
        case orderFront = "orderFront from A"
        case orderFrontRegardless = "orderFrontRegardless from A"
    }

    struct Reading {
        /// The window WindowServer's hit test names at the overlap point, or 0.
        let hit: UInt32
        /// The probe's windows on screen, front first.
        let order: [UInt32]
    }

    let a: KeyStub, b: KeyStub
    let a1: UInt32, b1: UInt32
    /// The center of the overlap, in AppKit's screen coordinates and in CoreGraphics'.
    let point: NSPoint, cgPoint: CGPoint
    var labels: [UInt32: String]

    init(policy: String) {
        a = KeyStub("A", arguments: ["float-stub", policy, "A", "0,0"])
        track(stub: a.process)
        b = KeyStub("B", arguments: ["float-stub", policy, "B", "50,50"])
        track(stub: b.process)
        a1 = a.windows[0]
        b1 = b.windows[0]
        labels = [a1: "A1", b1: "B1"]
        let origin = builtInScreen()?.visibleFrame.origin ?? .zero
        point = NSPoint(x: origin.x + 75, y: origin.y + 75)
        cgPoint = CGPoint(x: point.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - point.y)
        settle(0.3)   // let the windows reach the screen
    }

    /// Step 1. Returns the lowest level that kept B1 on top every way, and the memberships
    /// that did, or nil.
    func step1() -> (level: Int32, exclusive: [Bool])? {
        print("control, no float Space: B1 ordered front by B, then A1 each way")
        var control: [Raise] = []
        for way in Raise.allCases {
            raise(b1, of: b, .orderFrontRegardless)
            let before = read("B1 by orderFrontRegardless from B")
            raise(a1, of: a, way)
            let after = read("A1 by \(way.rawValue)")
            if before.hit == b1, after.hit == a1 { control.append(way) }
        }
        print("  A1 went over B1 by: \(control.map(\.rawValue).joined(separator: ", "))")
        guard !control.isEmpty else { print("no way ordered A1 over B1, so the float Space cannot be judged"); return nil }
        guard let desktop = Displays.current().currentSpace(at: cgPoint) else { print("the built-in display shows no ordinary Space"); return nil }
        let desktopLevel = SLSSpaceGetAbsoluteLevel(SkyLight.connection, desktop)
        print("the built-in display's current Space \(desktop) is at level \(desktopLevel); B1 is in \(ordinarySpaces(b1))")
        for level in [1, 2, 3, 10, 100].map({ desktopLevel + $0 }) {
            let space = kosmos_float_space_create(level)
            guard space != 0 else { print("level \(level): Space not created"); continue }
            track(space: space)
            print("level \(level): Space \(space), which reads level \(SLSSpaceGetAbsoluteLevel(SkyLight.connection, space))")
            var held: [Bool] = []
            for exclusive in [false, true] {
                add(b1, to: space, exclusive: exclusive)
                print("  B1 added \(exclusive ? "exclusively" : "keeping its ordinary Space"): \(membership(b1, space))")
                var readings = [read("B1 added")]
                for way in control {
                    raise(a1, of: a, way)
                    readings.append(read("A1 by \(way.rawValue)"))
                }
                // A window with no ordinary Space goes back to one before it leaves (section 5.3).
                if exclusive { add(b1, to: desktop, exclusive: true) }
                remove(b1, from: space)
                print("  B1 taken out: \(membership(b1, space))")
                if readings.allSatisfy({ $0.hit == b1 && $0.order.first == b1 }) { held.append(exclusive) }
            }
            print("  Space \(space) destroyed and gone: \(destroy(space))")
            if !held.isEmpty { return (level, held) }
        }
        return nil
    }

    /// Kills the stubs, checks that their windows are gone, and exits, which destroys any
    /// Space still tracked.
    func finish() -> Never {
        let windows = Array(labels.keys)
        a.process.terminate()
        b.process.terminate()
        print("stubs quit, their windows gone: \(poll { SkyLight.rows(windows).isEmpty })")
        exit(0)
    }

    /// WindowServer's hit test at the overlap point and the probe's windows in on-screen
    /// order, front first, each with its index in the whole list, printed after `step`.
    @discardableResult
    func read(_ step: String) -> Reading {
        let hit = UInt32(clamping: NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0))
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let mine = list.enumerated().compactMap { index, info -> (index: Int, id: UInt32, layer: Int)? in
            guard let id = (info[kCGWindowNumber as String] as? Int).map(UInt32.init), labels[id] != nil else { return nil }
            return (index, id, info[kCGWindowLayer as String] as? Int ?? 0)
        }
        let order = mine.map { "\(label($0.id)) #\($0.index)" + ($0.layer == 0 ? "" : " layer \($0.layer)") }
        print("  \(step): hit \(label(hit)); on screen \(order.joined(separator: ", "))")
        return Reading(hit: hit, order: mine.map(\.id))
    }

    func label(_ window: UInt32) -> String {
        if window == 0 { return "none" }
        if let label = labels[window] { return label }
        guard let row = SkyLight.rows([window]).first else { return "\(window)" }
        return "\(window) (\(NSRunningApplication(processIdentifier: row.pid)?.localizedName ?? "pid \(row.pid)"), level \(row.level))"
    }

    func raise(_ window: UInt32, of stub: KeyStub, _ way: Raise) {
        switch way {
        case .axRaise:
            guard let element = windowElement(stub.pid, window) else { return print("  no element for \(label(window))") }
            let result = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
            if result != .success { print("  AXRaise of \(label(window)) returned \(result.rawValue)") }
        case .orderFront: _ = stub.send("front \(window)")
        case .orderFrontRegardless: _ = stub.send("regardless \(window)")
        }
        settle(0.2)
    }

    func add(_ window: UInt32, to space: UInt64, exclusive: Bool) {
        var ids = [window]
        kosmos_add_windows(space, &ids, 1, exclusive)
        _ = kosmos_barrier(space)
    }

    func remove(_ window: UInt32, from space: UInt64) {
        var ids = [window]
        kosmos_remove_windows(space, &ids, 1)
        _ = kosmos_barrier(space)
    }

    func membership(_ window: UInt32, _ space: UInt64) -> String {
        "in Space \(space) \(inSpace(window, space)), ordinary Spaces \(ordinarySpaces(window))"
    }

    func ordinarySpaces(_ window: UInt32) -> [UInt64] { kosmos_window_spaces(window) as? [UInt64] ?? [] }

    /// Destroys the Space and returns whether it is gone.
    func destroy(_ space: UInt64) -> Bool {
        _ = kosmos_space_destroy(space)
        _ = kosmos_barrier(space)
        let gone = poll { kosmos_space_windows(space) == nil }
        if gone { untrack(space: space) }
        return gone
    }

    func settle(_ seconds: Double) { RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds)) }
}

/// A stub app for float-layer. Its arguments are its activation policy (prohibited, or
/// accessory to take focus), its name, then one "x,y" offset per window, in points from the
/// bottom left of the built-in display's visible frame. It prints the window ids on one line,
/// answers each command on standard input with one line (FloatStub.command), and exits when
/// standard input closes.
@MainActor func floatStub(_ arguments: [String]) -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(arguments.first == "accessory" ? .accessory : .prohibited)
    FloatStub.name = arguments.dropFirst().first ?? "S"
    FloatStub.origin = builtInScreen()?.visibleFrame.origin ?? .zero
    let color: NSColor = FloatStub.name == "B" ? .systemBlue : .systemRed
    let ids = arguments.dropFirst(2).map { FloatStub.open($0, level: 0, color: color) }
    print(ids.map(String.init).joined(separator: " "))
    Thread.detachNewThread {
        while let line = readLine() {
            print(DispatchQueue.main.sync { MainActor.assumeIsolated { FloatStub.command(line) } })
        }
        exit(0)
    }
    app.run()
    exit(0)
}

/// The stub's windows. Main thread only.
@MainActor enum FloatStub {
    static var name = ""
    static var origin = NSPoint.zero
    static var windows: [Int: NSWindow] = [:]

    /// Opens a 100 by 100 point window at `offset` ("x,y") and `level`, and returns its id.
    static func open(_ offset: String, level: Int, color: NSColor) -> Int {
        let xy = offset.split(separator: ",").compactMap { Double($0) }
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.title = "kosmos-probe \(name)"
        window.backgroundColor = color
        window.level = NSWindow.Level(rawValue: level)
        window.isReleasedWhenClosed = false
        window.setFrame(NSRect(x: origin.x + xy[0], y: origin.y + xy[1], width: 100, height: 100), display: false)
        window.orderFrontRegardless()
        windows[window.windowNumber] = window
        return window.windowNumber
    }

    /// "front <id>" calls orderFront, "regardless <id>" orderFrontRegardless, and
    /// "close <id>" closes the window. "open <x,y> <level>" opens an orange window at that
    /// level and replies with its id.
    static func command(_ line: String) -> String {
        let parts = line.split(separator: " ").map(String.init)
        let window = parts.count > 1 ? Int(parts[1]).flatMap { windows[$0] } : nil
        switch (parts.first, window) {
        case ("front", let window?): window.orderFront(nil)
        case ("regardless", let window?): window.orderFrontRegardless()
        case ("close", let window?):
            windows[window.windowNumber] = nil
            window.close()
        case ("open", _) where parts.count == 3:
            return String(open(parts[1], level: Int(parts[2]) ?? 0, color: .systemOrange))
        default: return "unknown command"
        }
        return "ok"
    }
}

@MainActor func builtInScreen() -> NSScreen? {
    NSScreen.screens.first { screen in
        let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        return id.map { CGDisplayIsBuiltin($0) != 0 } == true
    }
}

/// Waits up to a second for `done`, checking every 20 ms.
func poll(_ done: () -> Bool) -> Bool {
    for _ in 0..<50 {
        if done() { return true }
        usleep(20_000)
    }
    return done()
}

// What the probe leaves until it exits: its stubs and its Spaces, guarded by leftoversLock.
nonisolated(unsafe) private var leftovers: (stubs: [Process], spaces: [UInt64]) = ([], [])
private let leftoversLock = NSLock()
nonisolated(unsafe) private var signalSources: [DispatchSourceSignal] = []

private func track(stub: Process) {
    leftoversLock.withLock { leftovers.stubs.append(stub) }
}

private func track(space: UInt64) {
    leftoversLock.withLock { leftovers.spaces.append(space) }
}

private func untrack(space: UInt64) {
    leftoversLock.withLock { leftovers.spaces.removeAll { $0 == space } }
}

/// Cleans up at exit, and on SIGINT, SIGTERM and SIGHUP before exiting.
private func installCleanup() {
    atexit { cleanUp() }
    for signal in [SIGINT, SIGTERM, SIGHUP] {
        Darwin.signal(signal, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: signal, queue: .global())
        source.setEventHandler {
            cleanUp()
            _exit(128 + signal)
        }
        source.resume()
        signalSources.append(source)
    }
}

/// Kills the stubs, which takes their windows away, then destroys the Spaces. It keeps the
/// lock, so a second cleanup, from a signal during an exit or the reverse, waits until the
/// process is gone.
private func cleanUp() {
    leftoversLock.lock()
    let (stubs, spaces) = leftovers
    // terminate() leaves a stub that already exited alone, where kill could reach a reused pid.
    for stub in stubs { stub.terminate() }
    // A destroy may leave a Space that still holds a window (DESIGN.md, section 5.3), so
    // the stubs' windows leave first.
    _ = poll { spaces.allSatisfy { (kosmos_space_windows($0) as? [UInt32] ?? []).isEmpty } }
    for space in spaces { _ = kosmos_space_destroy(space) }
    guard let last = spaces.last else { return }
    _ = kosmos_barrier(last)
    _ = poll { spaces.allSatisfy { kosmos_space_windows($0) == nil } }
    for space in spaces where kosmos_space_windows(space) != nil { print("Space \(space) is still there") }
    print("cleanup destroyed Spaces \(spaces)")
}
