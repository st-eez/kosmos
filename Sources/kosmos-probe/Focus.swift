// How a window is made key, and which process holds focus (docs/focus.md).
//
//   kosmos-probe keying [rounds] [finder]
//                                   Keys windows of two stub apps four ways: the key record
//                                   alone, AXRaise then the record (the order Kosmos uses), the
//                                   record then AXRaise (yabai and alt-tab), and AXRaise alone.
//                                   Covers two stacked windows of one app, two side by side,
//                                   another app, and back into an app whose other window was
//                                   key; a background accessory app activating itself, as
//                                   Kosmos does for an empty workspace on the public path;
//                                   one with no window activating another app three ways,
//                                   as the public path does for every target, and the
//                                   private front with no key window that Kosmos uses for an
//                                   empty workspace, both on stub A and, with `finder`, on
//                                   Finder (it fronts Finder and moves none of its windows);
//                                   a background accessory app keying an invisible window of
//                                   its own by the private path, as an empty workspace
//                                   would, from itself and from another process;
//                                   then a key window concealed and revealed, where the focus
//                                   queue's already key check could skip wrongly, and an app
//                                   whose every window is concealed, with and without its
//                                   ordinary Space, fronted both ways to see whether it keys
//                                   one of them. The
//                                   stubs say which window they hold key, and every
//                                   AXFocusedWindowChanged is logged against the raise. They are
//                                   accessory apps with small windows at the bottom right, which
//                                   a running Kosmos leaves alone. The probe takes keyboard focus
//                                   while it runs and hands it back at the end.
//   kosmos-probe key-holder [seconds]  Who is front, who holds the key window and who owns
//                                   the menu bar: every 50 ms for 30 s by default, prints each
//                                   change of the front process (kosmos_front_pid), the key
//                                   focus process (kosmos_key_focus_pid) and NSWorkspace's
//                                   menuBarOwningApplication, with each app's name and
//                                   activation policy, then the time each read took. Passive:
//                                   open Raycast, Spotlight, a password prompt, Control Center
//                                   or a menu, or focus an empty workspace in Kosmos, while it
//                                   runs to see which read names what.
import AppKit
import CKosmos
import KosmosCore
import KosmosSkyLight

/// An accessory app for `keying`, which a running Kosmos leaves alone. Opens a 170 by 90
/// window for each "left,up" offset from the bottom right corner of the main screen's
/// visible area and prints the window ids. Each "key" line on its standard input prints the
/// window the app holds key, or 0. Each "activate" line activates the app from this
/// background thread, as Kosmos's focus queue activates Kosmos, and prints what `activate`
/// returned; "activate <way> <pid>" activates that app instead (ActivationWay). "invisible"
/// opens the window an empty workspace would key (InvisibleWindow) and prints its id, and
/// "key-self <id>" keys a window of the app's own by the private path from this background
/// thread, as Kosmos's focus queue would, and prints what the call returned. It exits when
/// its standard input closes.
@MainActor func keyStub(_ name: String, _ offsets: [String]) -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    let ids = offsets.enumerated().map { index, offset in
        let xy = offset.split(separator: ",").compactMap { Double($0) }
        let window = NSWindow(contentRect: NSRect(x: screen.maxX - 190 - xy[0], y: screen.minY + 20 + xy[1], width: 170, height: 90),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "kosmos-probe \(name)\(index + 1)"
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        return window.windowNumber
    }
    print(ids.map(String.init).joined(separator: " "))
    Thread.detachNewThread {
        while let line = readLine() {
            switch line {
            case "key": DispatchQueue.main.async { MainActor.assumeIsolated { print(NSApp.keyWindow?.windowNumber ?? 0) } }
            case "activate": print(NSRunningApplication.current.activate(options: []))
            case "invisible":
                DispatchQueue.main.sync { MainActor.assumeIsolated { print(InvisibleWindow.open()) } }
            default:
                let parts = line.split(separator: " ")
                if parts.count == 2, parts[0] == "key-self", let id = UInt32(parts[1]) {
                    print(kosmos_make_key(getpid(), id))
                    continue
                }
                guard parts.count == 3, parts[0] == "activate", let way = ActivationWay(rawValue: String(parts[1])),
                      let pid = pid_t(parts[2]) else { break }
                print(way.activate(pid))
            }
        }
        exit(0)
    }
    app.run()
    exit(0)
}

/// A window for an empty workspace to key: 1 by 1 point at the main screen's bottom left,
/// borderless, clear and transparent, ignoring the mouse, on every Space, and out of the
/// window cycle. A borderless window cannot become key unless it says so.
final class InvisibleWindow: NSWindow {
    override var canBecomeKey: Bool { true }

    @MainActor private static var opened: [InvisibleWindow] = []

    /// Opens one and returns its window id.
    @MainActor static func open() -> Int {
        let origin = NSScreen.main?.frame.origin ?? .zero
        let window = InvisibleWindow(contentRect: NSRect(origin: origin, size: NSSize(width: 1, height: 1)),
                                     styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle]
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        opened.append(window)
        return window.windowNumber
    }
}

/// How a background app with no window, as Kosmos is, asks for another app's activation
/// (`keying`). macOS 14 made activation cooperative: an app is asked to yield before
/// another activates from it.
enum ActivationWay: String, CaseIterable {
    /// `activate(options:)`, what Kosmos's public path calls.
    case plain
    /// This app yields to the target, then activates it from itself.
    case yield
    /// Activates the target from the front app, as if that app had yielded.
    case fromFront

    var label: String {
        switch self {
        case .plain: "activate"
        case .yield: "yield, then activate(from: itself)"
        case .fromFront: "activate(from: the front app)"
        }
    }

    /// Runs on the stub's background thread. Returns what the last call returned.
    func activate(_ pid: pid_t) -> Bool {
        guard let target = NSRunningApplication(processIdentifier: pid) else { return false }
        switch self {
        case .plain:
            return target.activate(options: [])
        case .yield:
            DispatchQueue.main.sync { MainActor.assumeIsolated { NSApp.yieldActivation(to: target) } }
            return target.activate(from: .current, options: [])
        case .fromFront:
            guard let front = NSWorkspace.shared.frontmostApplication else { return false }
            return target.activate(from: front, options: [])
        }
    }
}

final class KeyStub {
    let name: String
    /// The stub exits when its standard input closes.
    let child: Child
    let windows: [UInt32]
    var pid: pid_t { child.pid }

    init(_ name: String, _ offsets: [String]) {
        self.name = name
        child = Child(["key-stub", name] + offsets)
        windows = child.readWindows()
    }

    /// Activates the app from its own background thread. Returns what `activate` returned.
    func activateItself() -> Bool {
        child.send("activate")
        return child.line() == "true"
    }

    /// Opens an InvisibleWindow in the stub and returns its id.
    func openInvisibleWindow() -> UInt32 {
        child.send("invisible")
        return UInt32(child.line()) ?? 0
    }

    /// Keys a window of the stub's own by the private path, from the stub's background thread.
    func keyOwnWindow(_ id: UInt32) -> Bool {
        child.send("key-self \(id)")
        return child.line() == "true"
    }

    /// Activates another app from the stub's background thread. Returns what the call returned.
    func activate(_ pid: pid_t, _ way: ActivationWay) -> Bool {
        child.send("activate \(way.rawValue) \(pid)")
        return child.line() == "true"
    }

    /// The window the app itself holds key, from AppKit, or nil.
    func appKey() -> UInt32? {
        child.send("key")
        return UInt32(child.line()).flatMap { $0 == 0 ? nil : $0 }
    }

    func label(_ window: UInt32?) -> String {
        guard let window else { return "none" }
        return windows.firstIndex(of: window).map { "\(name)\($0 + 1)" } ?? String(window)
    }
}

/// The window's element in its app, found by window id.
func windowElement(_ pid: pid_t, _ window: UInt32) -> AXUIElement? {
    var windows: CFTypeRef?
    AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &windows)
    return (windows as? [AXUIElement])?.first { element in
        var id: UInt32 = 0
        return _AXUIElementGetWindow(element, &id) == .success && id == window
    }
}

/// The app's focused window as Accessibility names it.
func focusedWindow(of pid: pid_t) -> UInt32? {
    var focused: CFTypeRef?
    var id: UInt32 = 0
    guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute as CFString, &focused) == .success,
          let focused, _AXUIElementGetWindow((focused as! AXUIElement), &id) == .success else { return nil }
    return id
}

/// Every AXFocusedWindowChanged the stubs post, with when it arrived. Main thread only.
final class FocusNotes: @unchecked Sendable {
    var entries: [(pid: pid_t, window: UInt32, at: ContinuousClock.Instant)] = []
    private var observers: [AXObserver] = []

    func watch(_ pid: pid_t) {
        var observer: AXObserver?
        guard AXObserverCreate(pid, { _, element, _, refcon in
            guard let refcon else { return }
            var pid: pid_t = 0, window: UInt32 = 0
            AXUIElementGetPid(element, &pid)
            _ = _AXUIElementGetWindow(element, &window)
            Unmanaged<FocusNotes>.fromOpaque(refcon).takeUnretainedValue().entries.append((pid, window, .now))
        }, &observer) == .success, let observer else { return print("no focus observer for \(pid)") }
        AXObserverAddNotification(observer, AXUIElementCreateApplication(pid), kAXFocusedWindowChangedNotification as CFString,
                                  Unmanaged.passUnretained(self).toOpaque())
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers.append(observer)
    }
}

@MainActor func keying(rounds: Int, finder: Bool) {
    _ = NSApplication.shared   // the concealed cases' bridged operations need an AppKit client
    guard AXIsProcessTrusted() else { print("this terminal needs Accessibility permission"); exit(1) }
    // Focus goes back to this app and window at the end.
    let before = NSWorkspace.shared.frontmostApplication?.processIdentifier
    let beforeWindow = before.flatMap(focusedWindow(of:))
    let keying = Keying(rounds: max(rounds, 1))
    defer {
        keying.a.child.terminate()
        keying.b.child.terminate()
        if let before, let beforeWindow { _ = kosmos_make_key(before, beforeWindow) }
    }
    keying.wait(0.5)
    keying.orders()
    keying.selfActivation()
    // S has no window, as Kosmos has none.
    let s = KeyStub("S", [])
    defer { s.child.terminate() }
    keying.activations(from: s, finder: finder)
    keying.invisibleWindow(of: s)
    keying.concealed(frontingFrom: s)
    print("\nsummary: a hit keys the target window in the app that holds it; a miss leaves another window key")
    for line in keying.summary { print("  " + line) }
}

/// What the phases of `keying` share: stubs A and B, the focus notes, how a window is keyed and
/// how the result is read, and each phase's summary.
@MainActor final class Keying {
    enum Order: String, CaseIterable {
        case recordOnly = "record only"
        case raiseFirst = "AXRaise, then record"
        case raiseAfter = "record, then AXRaise"
        /// As the worker's raise after the key record: only while the app is front and the
        /// target is its focused window, read just after the record.
        case postRaise = "record, then AXRaise while front and focused"
        case raiseOnly = "AXRaise alone"
    }

    let rounds: Int
    // A1 and A2 overlap, A3 sits apart, and B1 covers parts of A1 and A2.
    let a = KeyStub("A", ["0,0", "60,40", "300,0"])
    let b = KeyStub("B", ["30,20"])
    let notes = FocusNotes()
    /// Each phase's results, printed at the end.
    var summary: [String] = []

    init(rounds: Int) {
        self.rounds = rounds
        notes.watch(a.pid)
        notes.watch(b.pid)
    }

    func wait(_ seconds: Double) { RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds)) }

    /// Keys the window as `order` says and waits 0.3 s. Returns when the raise started, and
    /// how long it took.
    @discardableResult
    func focus(_ stub: KeyStub, _ window: UInt32, _ order: Order) -> (raised: ContinuousClock.Instant, ms: Double)? {
        var raise: (ContinuousClock.Instant, Double)?
        func raiseWindow() {
            guard let element = windowElement(stub.pid, window) else { return print("  no element for \(stub.label(window))") }
            let start = ContinuousClock.now
            _ = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
            raise = (start, elapsed(start))
        }
        if order == .raiseFirst || order == .raiseOnly { raiseWindow() }
        if order != .raiseOnly, !kosmos_make_key(stub.pid, window) { print("  kosmos_make_key failed for \(stub.label(window))") }
        if order == .raiseAfter { raiseWindow() }
        if order == .postRaise {
            let focused = focusedWindow(of: stub.pid), front = kosmos_front_pid() == stub.pid
            if front, focused == window {
                raiseWindow()
            } else {
                print("  raise skipped: front \(front ? "yes" : "no"), AX focused \(stub.label(focused))")
            }
        }
        wait(0.3)
        return raise
    }

    func front(_ stub: KeyStub) -> Bool { NSWorkspace.shared.frontmostApplication?.processIdentifier == stub.pid }

    func onTop(_ window: UInt32, over others: [UInt32]) -> Bool {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let order = list.compactMap { ($0[kCGWindowNumber as String] as? Int).map(UInt32.init) }
        guard let index = order.firstIndex(of: window) else { return false }
        return others.allSatisfy { (order.firstIndex(of: $0) ?? .max) > index }
    }

    /// The focus notes since `mark`, as offsets from the raise when there was one.
    func notesSince(_ mark: Int, raisedAt: ContinuousClock.Instant?) -> String {
        let stubs = [a, b]
        let text = notes.entries[mark...].map { note in
            let stub = stubs.first { $0.pid == note.pid }
            let offset = raisedAt.map { String(format: " %+.1f ms", Double((note.at - $0).components.attoseconds) / 1e15
                                                                 + Double((note.at - $0).components.seconds) * 1000) } ?? ""
            return "\(stub?.label(note.window) ?? String(note.window))\(offset)"
        }
        return text.isEmpty ? "none" : text.joined(separator: ", ")
    }

    /// Each case's target keyed in each order, after Kosmos's order keyed the case's setup.
    func orders() {
        typealias Target = (stub: KeyStub, window: UInt32)
        let cases: [(name: String, setup: [Target], target: Target, covers: [UInt32])] = [
            ("same app, stacked: A2 key, then A1", [(a, a.windows[1])], (a, a.windows[0]), [a.windows[1]]),
            ("same app, side by side: A1 key, then A3", [(a, a.windows[0])], (a, a.windows[2]), []),
            ("other app: A1 key, then B1", [(a, a.windows[0])], (b, b.windows[0]), [a.windows[0], a.windows[1]]),
            ("back into A after A2 was key: A2, B1, then A1", [(a, a.windows[1]), (b, b.windows[0])], (a, a.windows[0]),
             [a.windows[1], b.windows[0]]),
        ]
        var hits: [String: Int] = [:], raised: [String: Int] = [:], trials: [String: Int] = [:]
        var raiseTimes: [Double] = []
        for round in 1...rounds {
            for test in cases {
                for order in Order.allCases {
                    // A case whose setup did not key is skipped.
                    for step in test.setup { focus(step.stub, step.window, .raiseFirst) }
                    let last = test.setup.last!
                    guard front(last.stub), last.stub.appKey() == last.window else {
                        print("round \(round), \(test.name), \(order.rawValue): setup did not key \(last.stub.label(last.window)), skipped")
                        continue
                    }
                    let mark = notes.entries.count
                    let raise = focus(test.target.stub, test.target.window, order)
                    if let raise { raiseTimes.append(raise.ms) }
                    let isFront = front(test.target.stub)
                    let appKey = test.target.stub.appKey()
                    let axFocused = focusedWindow(of: test.target.stub.pid)
                    let isKey = isFront && appKey == test.target.window
                    let isOnTop = onTop(test.target.window, over: test.covers)
                    let row = "\(test.name) | \(order.rawValue)"
                    trials[row, default: 0] += 1
                    if isKey { hits[row, default: 0] += 1 }
                    if isOnTop { raised[row, default: 0] += 1 }
                    let raiseTime = raise.map { String(format: ", AXRaise %.2f ms", $0.ms) } ?? ""
                    print("round \(round), \(row): \(isKey ? "keyed" : "NOT KEYED") (front \(isFront ? "yes" : "no"), "
                          + "app key \(test.target.stub.label(appKey)), AX focused \(test.target.stub.label(axFocused))), "
                          + "\(isOnTop ? "on top" : "not on top")\(raiseTime); focus notes: \(notesSince(mark, raisedAt: raise?.raised))")
                }
            }
        }
        for test in cases {
            for order in Order.allCases {
                let row = "\(test.name) | \(order.rawValue)"
                let hit = hits[row] ?? 0, runs = trials[row] ?? 0
                summary.append("\(row): \(hit) hits, \(runs - hit) misses, on top \(raised[row] ?? 0) of \(runs)")
            }
        }
        if !raiseTimes.isEmpty {
            summary.append(String(format: "AXRaise: median %.2f ms, max %.2f ms over %d raises", percentile(raiseTimes, 0.5),
                                  percentile(raiseTimes, 1), raiseTimes.count))
        }
    }

    /// B, an accessory app in the background, activating itself, as Kosmos does for an empty
    /// workspace on the public path.
    func selfActivation() {
        var selfActivated = 0, selfTrials = 0
        for round in 1...rounds {
            focus(a, a.windows[0], .raiseFirst)
            guard front(a) else {
                print("round \(round), self-activation: setup did not front A, skipped")
                continue
            }
            let returned = b.activateItself()
            wait(0.3)
            let isFront = front(b)
            selfTrials += 1
            if isFront { selfActivated += 1 }
            print("round \(round), B activating itself from the background: activate returned \(returned), "
                  + "B \(isFront ? "is" : "is NOT") the front app 0.3 s later")
        }
        summary.append("a background accessory app activating itself became front in \(selfActivated) of \(selfTrials)")
    }

    /// `s`, with no window, activating another app, as the public path does for every target,
    /// then the private front with no key window, which the private path uses for an empty
    /// workspace. B is front before each try.
    func activations(from s: KeyStub, finder: Bool) {
        let finderPid = finder ? NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.processIdentifier : nil
        var targets: [(name: String, pid: pid_t)] = [("A", a.pid)]
        if let finderPid { targets.append(("Finder", finderPid)) }
        var fronted: [String: Int] = [:], tries: [String: Int] = [:]
        func frontPid() -> pid_t? { NSWorkspace.shared.frontmostApplication?.processIdentifier }
        // nil is the private front with no key window.
        let ways: [ActivationWay?] = ActivationWay.allCases + [nil]
        for round in 1...rounds {
            for target in targets {
                for way in ways {
                    focus(b, b.windows[0], .raiseFirst)
                    let label = way.map { "S \($0.label)" } ?? "kosmos_front_without_windows"
                    guard front(b) else {
                        print("round \(round), \(target.name) by \(label): setup did not front B, skipped")
                        continue
                    }
                    let returned = way.map { s.activate(target.pid, $0) } ?? kosmos_front_without_windows(target.pid)
                    wait(0.3)
                    let isFront = frontPid() == target.pid
                    let key = target.pid == a.pid ? a.label(a.appKey()) : focusedWindow(of: target.pid).map(String.init) ?? "none"
                    let row = "\(target.name) by \(label)"
                    tries[row, default: 0] += 1
                    if isFront { fronted[row, default: 0] += 1 }
                    print("round \(round), \(row): returned \(returned), \(target.name) \(isFront ? "is" : "is NOT") front 0.3 s later, "
                          + "its key window \(key)")
                }
            }
        }
        for row in tries.keys.sorted() {
            summary.append("\(row): front in \(fronted[row] ?? 0) of \(tries[row] ?? 0)")
        }
    }

    /// Kosmos keying a window of its own for an empty workspace: `s`'s invisible window, keyed
    /// by the private path from `s`'s own background thread and from another process. B is
    /// front before each try.
    func invisibleWindow(of s: KeyStub) {
        let invisible = s.openInvisibleWindow()
        var ownKeyed: [String: Int] = [:], ownTries: [String: Int] = [:]
        let ownWays: [(label: String, key: () -> Bool)] = [
            ("S keying its invisible window itself", { s.keyOwnWindow(invisible) }),
            ("the probe keying S's invisible window", { kosmos_make_key(s.pid, invisible) }),
        ]
        for round in 1...rounds where invisible != 0 {
            for way in ownWays {
                focus(b, b.windows[0], .raiseFirst)
                guard front(b) else {
                    print("round \(round), \(way.label): setup did not front B, skipped")
                    continue
                }
                let returned = way.key()
                wait(0.3)
                let isFront = front(s), appKey = s.appKey()
                ownTries[way.label, default: 0] += 1
                if isFront && appKey == invisible { ownKeyed[way.label, default: 0] += 1 }
                print("round \(round), \(way.label): returned \(returned), S \(isFront ? "is" : "is NOT") front 0.3 s later, "
                      + "its key window \(appKey.map { $0 == invisible ? "the invisible one" : String($0) } ?? "none"), "
                      + "B \(front(b) ? "still front" : "not front")")
            }
        }
        if invisible == 0 { print("S opened no invisible window; its case did not run") }
        for way in ownWays {
            summary.append("\(way.label): S front with it key in \(ownKeyed[way.label] ?? 0) of \(ownTries[way.label] ?? 0)")
        }
    }

    /// The cases with A's windows in a holding Space: a key window concealed and revealed, then
    /// every window of A concealed while `s` fronts A.
    func concealed(frontingFrom s: KeyStub) {
        let space = kosmos_holding_create()
        guard let desktop = Displays.current().ordinarySpace(original: nil), space != 0 else {
            if space != 0 { kosmos_space_destroy(space) }
            return print("no holding Space or no ordinary Space; the concealed cases did not run")
        }
        defer {
            var every = a.windows
            kosmos_remove_windows(space, &every, every.count)
            kosmos_space_destroy(space)
        }
        concealedAndRevealed(in: space, desktop: desktop)
        everyWindowConcealed(in: space, desktop: desktop, frontingFrom: s)
    }

    /// A key window concealed and revealed again, as a switch away and back does. The focus
    /// queue skips a request when the app is front and names the target as focused; it would
    /// skip wrongly if the app named it while holding no key window.
    private func concealedAndRevealed(in space: UInt64, desktop: UInt64) {
        var wrongSkips = 0, concealTrials = 0, rekeyed = 0
        var ids = [a.windows[0]]
        for round in 1...rounds {
            focus(a, a.windows[0], .raiseFirst)
            guard front(a), a.appKey() == a.windows[0] else {
                print("round \(round), concealed and revealed: setup did not key A1, skipped")
                continue
            }
            kosmos_add_windows(space, &ids, 1, true)
            _ = kosmos_barrier(space)
            wait(0.3)
            print("round \(round), A1 concealed: front \(front(a) ? "yes" : "no"), app key \(a.label(a.appKey())), "
                  + "AX focused \(a.label(focusedWindow(of: a.pid)))")
            kosmos_add_windows(desktop, &ids, 1, true)
            kosmos_remove_windows(space, &ids, 1)
            _ = kosmos_barrier(space)
            wait(0.3)
            let isFront = front(a), appKey = a.appKey(), axFocused = focusedWindow(of: a.pid)
            let skips = !focusGoesAhead(to: a.windows[0], appIsFront: isFront, focused: .some(axFocused))
            let wrong = skips && appKey != a.windows[0]
            concealTrials += 1
            if wrong { wrongSkips += 1 }
            let mark = notes.entries.count
            let raise = focus(a, a.windows[0], .raiseFirst)
            let keyedAgain = front(a) && a.appKey() == a.windows[0]
            if keyedAgain { rekeyed += 1 }
            print("round \(round), A1 revealed: front \(isFront ? "yes" : "no"), app key \(a.label(appKey)), "
                  + "AX focused \(a.label(axFocused)); the already key check would \(skips ? "skip" : "go ahead")"
                  + "\(wrong ? ", WRONGLY" : ""); Kosmos's order then \(keyedAgain ? "keyed A1" : "did NOT key A1"); "
                  + "focus notes: \(notesSince(mark, raisedAt: raise?.raised))")
        }
        summary.append("concealed and revealed: the already key check skipped wrongly in \(wrongSkips) of \(concealTrials); "
                       + "Kosmos's order keyed A1 again in \(rekeyed) of \(concealTrials)")
    }

    /// An app whose every window is concealed, fronted as an empty workspace fronts Finder, by
    /// `s`'s activate and by the private front with no key window: whether it keys a concealed
    /// window, with the windows kept in their ordinary Space or not. B is front before each try.
    private func everyWindowConcealed(in space: UInt64, desktop: UInt64, frontingFrom s: KeyStub) {
        var concealedKeys: [String: Int] = [:], concealedTries: [String: Int] = [:]
        for round in 1...rounds {
            for exclusive in [false, true] {
                for way in [ActivationWay.plain, nil] as [ActivationWay?] {
                    focus(a, a.windows[0], .raiseFirst)
                    var all = a.windows
                    kosmos_add_windows(space, &all, all.count, exclusive)
                    _ = kosmos_barrier(space)
                    focus(b, b.windows[0], .raiseFirst)
                    let row = "A's windows \(exclusive ? "concealed exclusively" : "concealed in their ordinary Space too"), "
                        + "A fronted by \(way.map { "S \($0.label)" } ?? "kosmos_front_without_windows")"
                    if front(b) {
                        let returned = way.map { s.activate(a.pid, $0) } ?? kosmos_front_without_windows(a.pid)
                        wait(0.3)
                        let appKey = a.appKey(), axFocused = focusedWindow(of: a.pid)
                        concealedTries[row, default: 0] += 1
                        if appKey != nil { concealedKeys[row, default: 0] += 1 }
                        print("round \(round), \(row): returned \(returned), A \(front(a) ? "is" : "is NOT") front, "
                              + "app key \(a.label(appKey)), AX focused \(a.label(axFocused))")
                    } else {
                        print("round \(round), \(row): setup did not front B, skipped")
                    }
                    // An exclusively concealed window needs an ordinary Space before it leaves.
                    if exclusive { kosmos_add_windows(desktop, &all, all.count, true) }
                    kosmos_remove_windows(space, &all, all.count)
                    _ = kosmos_barrier(space)
                    wait(0.2)
                }
            }
        }
        for row in concealedTries.keys.sorted() {
            summary.append("\(row): A keyed a concealed window in \(concealedKeys[row] ?? 0) of \(concealedTries[row] ?? 0)")
        }
    }
}

@MainActor func keyHolder(seconds: Double) -> Never {
    func describe(_ pid: pid_t) -> String {
        guard pid != 0 else { return "none" }
        guard let app = NSRunningApplication(processIdentifier: pid) else { return "pid \(pid)" }
        let policy = switch app.activationPolicy {
        case .regular: "regular"
        case .accessory: "accessory"
        case .prohibited: "prohibited"
        @unknown default: "unknown"
        }
        return "\(app.localizedName ?? "pid \(pid)") (\(pid), \(policy))"
    }
    var frontTimes: [Double] = [], holderTimes: [Double] = []
    var last: (front: pid_t, holder: pid_t, menuBar: pid_t) = (-1, -1, -1)
    let end = ContinuousClock.now + .seconds(seconds)
    print("watching the front, key focus and menu bar owning processes for \(seconds) s")
    while ContinuousClock.now < end {
        var start = ContinuousClock.now
        let front = kosmos_front_pid()
        frontTimes.append(elapsed(start))
        start = ContinuousClock.now
        let holder = kosmos_key_focus_pid()
        holderTimes.append(elapsed(start))
        let menuBar = NSWorkspace.shared.menuBarOwningApplication?.processIdentifier ?? 0
        if (front, holder, menuBar) != last {
            print("""
                \(Date().formatted(date: .omitted, time: .standard)) front \(describe(front)), key focus \(describe(holder)), \
                menu bar \(describe(menuBar))
                """)
            last = (front, holder, menuBar)
        }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
    }
    for (name, times) in [("front", frontTimes), ("key focus", holderTimes)] {
        let sorted = times.sorted()
        print(String(format: "%@ read: median %.1f us, max %.1f us over %d reads", name,
                     sorted[sorted.count / 2] * 1000, sorted.last! * 1000, sorted.count))
    }
    exit(0)
}
