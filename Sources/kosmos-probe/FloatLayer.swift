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
// Only then does step 2 run, with B1 in a float Space at that level. It checks that the hit
// test still names B1 and the window list still shows it, that Accessibility moves and
// resizes it, and how it orders against other windows: A2, a window of A at the normal level,
// as a panel or dialog, at the floating, status and pop-up menu levels, and at the levels
// SketchyBar, the Dock and the menu bar use, read from the window list; then B2, a window of
// B's own at the normal and pop-up menu levels, and a sheet of B1. Then it conceals B1 in a
// holding Space and reveals it, with B1 kept in the float Space and moved out of it, and
// last takes B1 out and destroys the Space, read back. After step 2, B1 goes into Spaces at
// the desktop Space's own level with ordering weights 0, -1000 and 1000, to see whether a
// weight lifts it over A1 while A's pop-up menu level window stays over it.
//
// kosmos-probe float-layer key takes focus, for a run at the desk. With B1 in a float Space
// one level above the desktop Space's, it keys B1 as Kosmos keys another app's window (the
// key record, then AXRaise), asks for a few keystrokes and reports which stub got them, then
// keys A1 the same way and checks that B1 stays on top of it. At the end it keys the window
// that was key before.
//
// The stubs have the prohibited activation policy, so they can never be the front process
// and Kosmos leaves them alone; without key the probe takes no focus. In the key mode they
// are accessory apps, which Kosmos leaves alone too. The windows show for a few seconds.
// However the probe exits, Ctrl-C included, it kills the stubs, which takes their windows
// away, then destroys its Spaces; only a SIGKILL leaves the Spaces, empty. Needs
// Accessibility for the terminal; the probe never asks for it.
import AppKit
import CKosmos
import KosmosSkyLight

@MainActor func floatLayer(key: Bool) -> Never {
    guard AXIsProcessTrusted() else { print("this terminal needs Accessibility permission"); exit(1) }
    let app = NSApplication.shared   // bridged operations need an AppKit client
    app.setActivationPolicy(.prohibited)
    guard builtInScreen() != nil else { print("no built-in display"); exit(1) }
    installCleanup()
    let probe = FloatLayer(policy: key ? "accessory" : "prohibited")
    guard let desktop = Displays.current().currentSpace(at: probe.cgPoint) else {
        print("the built-in display shows no ordinary Space")
        probe.finish()
    }
    let desktopLevel = SLSSpaceGetAbsoluteLevel(SkyLight.connection, desktop)
    print("the built-in display's current Space \(desktop) is at level \(desktopLevel); B1 is in \(probe.ordinarySpaces(probe.b1))")
    if key {
        probe.key(level: desktopLevel + 1)
    } else if let found = probe.step1(desktop: desktop, desktopLevel: desktopLevel) {
        let ways = found.exclusive.map { $0 ? "added exclusively" : "keeping its ordinary Space" }
        print("step 1: yes. At level \(found.level), B1 stayed on top every way, \(ways.joined(separator: " and "))")
        probe.step2(level: found.level, exclusive: found.exclusive[0], desktop: desktop)
        probe.orderingWeights(level: desktopLevel)
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
    func step1(desktop: UInt64, desktopLevel: Int32) -> (level: Int32, exclusive: [Bool])? {
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
                for way in Raise.allCases {
                    raise(a1, of: a, way)
                    readings.append(read("A1 by \(way.rawValue)"))
                }
                takeOut(b1, from: space, exclusive: exclusive, desktop: desktop)
                if readings.allSatisfy({ $0.hit == b1 && $0.order.first == b1 }) { held.append(exclusive) }
            }
            print("  Space \(space) destroyed and gone: \(destroy(space))")
            if !held.isEmpty { return (level, held) }
        }
        return nil
    }

    /// Step 2, with B1 in a float Space at `level`, added as step 1 found it held.
    func step2(level: Int32, exclusive: Bool, desktop: UInt64) {
        let space = kosmos_float_space_create(level)
        guard space != 0 else { return print("step 2: Space not created") }
        track(space: space)
        add(b1, to: space, exclusive: exclusive)
        print("step 2: B1 in Space \(space) at level \(level), \(exclusive ? "added exclusively" : "keeping its ordinary Space")")
        raise(a1, of: a, .axRaise)
        let start = read("A1 by AXRaise")
        print("  B1 takes clicks: \(start.hit == b1); in the on-screen list: \(start.order.contains(b1))")

        if let element = windowElement(b.pid, b1), let frame = SkyLight.rows([b1]).first?.frame {
            let moved = setFrame(element, CGRect(x: frame.minX + 10, y: frame.minY - 10, width: 120, height: 120))
            settle(0.2)
            print("  AX move and resize returned \(moved.map(\.rawValue)); WindowServer frame \(frame) is now "
                  + "\(SkyLight.rows([b1]).first?.frame ?? .null), AX reads \(axFrame(element)); \(membership(b1, space))")
            read("B1 moved and resized")
            _ = setFrame(element, frame)
        } else {
            print("  no element or row for B1")
        }

        var above: [Int] = [], below: [Int] = []
        for (level, what) in otherLevels() {
            guard let id = UInt32(a.send("open 25,25 \(level)")) else { continue }
            labels[id] = "A2"
            settle(0.2)
            let reading = read("A2 opened at level \(level), \(what)")
            if reading.hit == b1 { above.append(level) } else { below.append(level) }
            _ = a.send("close \(id)")
        }
        print("  B1 is over A's windows at levels \(above) and under those at \(below)")
        for level in [0, 101] {
            guard let id = UInt32(b.send("open 25,25 \(level)")) else { continue }
            labels[id] = "B2"
            settle(0.2)
            print("  B2, B's own window at level \(level): \(membership(id, space))")
            read("B2 opened")
            _ = b.send("close \(id)")
        }

        if let sheet = UInt32(b.send("sheet \(b1)")) {
            labels[sheet] = "B1's sheet"
            settle(0.5)   // the sheet's animation
            print("  B1's sheet opened: \(membership(sheet, space))")
            read("sheet opened")
            raise(a1, of: a, .axRaise)
            read("A1 by AXRaise")
            _ = b.send("end-sheet \(b1)")
            settle(0.5)
        }

        let holding = kosmos_holding_create()
        if holding != 0 {
            track(space: holding)
            // Kosmos conceals a window by adding it to the holding Space, keeping its other Spaces.
            add(b1, to: holding, exclusive: false)
            print("  B1 concealed while it stays in the float Space: \(membership(b1, holding)); \(membership(b1, space))")
            read("concealed")
            raise(a1, of: a, .axRaise)
            remove(b1, from: holding)
            read("A1 by AXRaise, then B1 revealed")
            remove(b1, from: space)
            add(b1, to: holding, exclusive: false)
            print("  B1 moved from the float Space to the holding Space: \(membership(b1, holding)); \(membership(b1, space))")
            read("concealed")
            raise(a1, of: a, .axRaise)
            add(b1, to: space, exclusive: exclusive)
            remove(b1, from: holding)
            print("  B1 moved back: \(membership(b1, holding)); \(membership(b1, space))")
            read("A1 by AXRaise, then B1 revealed into the float Space")
            print("  holding Space \(holding) destroyed and gone: \(destroy(holding))")
        } else {
            print("  holding Space not created")
        }

        takeOut(b1, from: space, exclusive: exclusive, desktop: desktop)
        print("  float Space \(space) destroyed and gone: \(destroy(space)); B1 is in \(ordinarySpaces(b1))")
        raise(a1, of: a, .axRaise)
        print("  A1 goes over B1 again: \(read("A1 by AXRaise").hit == a1)")
    }

    /// B1 in a float Space at the desktop Space's own level, with ordering weights: does B1
    /// stay over A1 whichever way A1 is ordered, and under A's pop-up menu level window?
    func orderingWeights(level: Int32) {
        for weight: Int32 in [0, -1000, 1000] {
            let space = kosmos_float_space_create(level)
            guard space != 0 else { print("level \(level): Space not created"); continue }
            track(space: space)
            let set = kosmos_space_set_ordering_weight(space, weight)
            add(b1, to: space, exclusive: false)
            print("level \(level), ordering weight \(weight) (sent \(set)): B1 \(membership(b1, space))")
            read("B1 added")
            for way in Raise.allCases {
                raise(a1, of: a, way)
                read("A1 by \(way.rawValue)")
            }
            if let id = UInt32(a.send("open 25,25 101")) {
                labels[id] = "A2"
                settle(0.2)
                read("A2 opened at level 101")
                _ = a.send("close \(id)")
                settle(0.2)   // the window's close animation
            }
            takeOut(b1, from: space, exclusive: false, desktop: 0)
            print("  Space \(space) destroyed and gone: \(destroy(space))")
        }
    }

    /// Keys B1 in a float Space at `level`, then A1, as Kosmos keys another app's window, and
    /// reads which stub gets the keystrokes typed meanwhile. Takes focus, and gives it back.
    func key(level: Int32) {
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let frontWindow = front.flatMap(focusedWindow(of:))
        defer { if let front, let frontWindow { _ = kosmos_make_key(front, frontWindow) } }
        let space = kosmos_float_space_create(level)
        guard space != 0 else { return print("Space not created") }
        track(space: space)
        add(b1, to: space, exclusive: false)
        print("B1 in Space \(space) at level \(level): \(membership(b1, space))")
        for (stub, window, other, otherWindow) in [(b, b1, a, a1), (a, a1, b, b1)] {
            let keyed = kosmos_make_key(stub.pid, window)
            settle(0.2)
            print("\(label(window)) key record sent \(keyed): \(focus(stub, window))")
            raise(window, of: stub, .axRaise)
            print("  then AXRaise: \(focus(stub, window))")
            read("\(label(window)) keyed")
            _ = stub.send("typed")
            _ = other.send("typed")
            print("  type a few keys within 5 s")
            settle(5)
            print("  \(label(window)) got \(stub.send("typed").debugDescription), \(label(otherWindow)) got \(other.send("typed").debugDescription)")
        }
        takeOut(b1, from: space, exclusive: false, desktop: 0)
        print("float Space \(space) destroyed and gone: \(destroy(space))")
    }

    /// Whether the stub is the front process, holds the key focus and has `window` key.
    func focus(_ stub: KeyStub, _ window: UInt32) -> String {
        let key = UInt32(stub.send("key")) ?? 0
        return "front \(kosmos_front_pid() == stub.pid), key focus \(kosmos_key_focus_pid() == stub.pid), "
            + "its key window \(label(key))"
    }

    /// Takes the window out of the float Space. A window with no ordinary Space, as one added
    /// exclusively, goes back to one first (DESIGN.md, section 5.3).
    func takeOut(_ window: UInt32, from space: UInt64, exclusive: Bool, desktop: UInt64) {
        if exclusive { add(window, to: desktop, exclusive: true) }
        remove(window, from: space)
        print("  \(label(window)) taken out: \(membership(window, space))")
    }

    /// The levels of A's other windows to order B1 against: a second window at the normal
    /// level, as a panel or dialog, the floating, status and pop-up menu levels, and the levels
    /// SketchyBar, the Dock and the menu bar's MenuBarAgent use now, read from the window list.
    func otherLevels() -> [(level: Int, what: String)] {
        var levels = [(0, "a second window"), (3, "floating"), (25, "status"), (101, "pop-up menu")]
        let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        for owner in ["sketchybar", "Dock", "MenuBarAgent"] {
            let used = Set(list.filter { $0[kCGWindowOwnerName as String] as? String == owner }
                .compactMap { $0[kCGWindowLayer as String] as? Int }.filter { $0 != 0 })
            levels += used.sorted().map { ($0, owner) }
        }
        return levels.sorted { $0.0 < $1.0 }
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

/// Sets the window's position and size through Accessibility, and returns each result.
func setFrame(_ element: AXUIElement, _ frame: CGRect) -> [AXError] {
    var origin = frame.origin, size = frame.size
    return [AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &origin)!),
            AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &size)!)]
}

/// The window's frame as Accessibility reads it.
func axFrame(_ element: AXUIElement) -> CGRect {
    var position: CFTypeRef?, size: CFTypeRef?
    var frame = CGRect.null
    if AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
       AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success {
        frame = .zero
        AXValueGetValue(position as! AXValue, .cgPoint, &frame.origin)
        AXValueGetValue(size as! AXValue, .cgSize, &frame.size)
    }
    return frame
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

/// The stub's windows, and what was typed into them. Main thread only.
@MainActor enum FloatStub {
    static var name = ""
    static var origin = NSPoint.zero
    static var windows: [Int: NSWindow] = [:]
    static var typed = ""

    /// Opens a 100 by 100 point window at `offset` ("x,y") and `level`, and returns its id.
    static func open(_ offset: String, level: Int, color: NSColor) -> Int {
        let xy = offset.split(separator: ",").compactMap { Double($0) }
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.title = "kosmos-probe \(name)"
        window.backgroundColor = color
        window.level = NSWindow.Level(rawValue: level)
        window.isReleasedWhenClosed = false
        window.contentView = TypingView()
        window.makeFirstResponder(window.contentView)
        window.setFrame(NSRect(x: origin.x + xy[0], y: origin.y + xy[1], width: 100, height: 100), display: false)
        window.orderFrontRegardless()
        windows[window.windowNumber] = window
        return window.windowNumber
    }

    /// "front <id>" calls orderFront, "regardless <id>" orderFrontRegardless, and
    /// "close <id>" closes the window. "open <x,y> <level>" opens an orange window at that
    /// level and replies with its id. "sheet <id>" begins a sheet on the window and replies
    /// with its id, and "end-sheet <id>" ends it. "key" replies with the window the app holds
    /// key, or 0, and "typed" with what was typed into its windows since the last "typed".
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
        case ("sheet", let window?):
            let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 90, height: 70), styleMask: [.titled],
                                 backing: .buffered, defer: false)
            sheet.backgroundColor = .systemTeal
            window.beginSheet(sheet)
            return String(sheet.windowNumber)
        case ("end-sheet", let window?):
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
        case ("key", _): return String(NSApp.keyWindow?.windowNumber ?? 0)
        case ("typed", _):
            defer { typed = "" }
            return typed
        default: return "unknown command"
        }
        return "ok"
    }
}

/// Takes typing: each key pressed in its window adds its characters to FloatStub.typed.
final class TypingView: NSView {
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { FloatStub.typed += event.characters ?? "" }
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
