// Probes for private behaviour the design depends on. Each probe touches only windows it
// creates itself.
//
//   kosmos-probe bar                Checks SketchyBar's wire format with a read-only query,
//                                   and times sends of an event no item subscribes to.
//   kosmos-probe gone-space-recovery  Recovery of a record that names a destroyed Space, as
//                                   a crash between destroying and clearing would leave it.
//   kosmos-probe displays           Each display's identity as Kosmos reads it: EDID
//                                   serial, framebuffer, and the bar number, checked against
//                                   SketchyBar's own when it runs. Read only. Every
//                                   framebuffer and the EDID fields it publishes, with or
//                                   without a display:
//                                   ioreg -rtc IOMobileFramebufferShim -d1 -w0 | grep -E '\+-o disp|ProductAttributes'
//   kosmos-probe secure-input       Which Carbon hotkeys fire while Secure Input is on, from
//                                   real key presses its window asks for (SecureInput.swift).
//   kosmos-probe ax-timeout         What Accessibility returns, and how long it takes, for a
//                                   child app that is launching, answering and hung. The
//                                   child is an accessory app with no window, which a running
//                                   Kosmos ignores. Needs Accessibility for the terminal.
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
//   kosmos-probe level [onscreen|opaque]  Does WindowServer report a change of a window's
//                                   level? A window of its own, invisible and off every
//                                   display, in an app with the prohibited activation policy,
//                                   goes to the floating level and back three times. onscreen
//                                   puts it in a corner of the main display, still invisible;
//                                   opaque gives it full alpha off every display. Every
//                                   SkyLight notification from 750 to 1799 is registered, and
//                                   the window is watched. Prints every event in time order
//                                   with the level changes, then counts the events of other ids
//                                   near a change and at other times.
//   kosmos-probe key-holder [seconds]  Who is front, who holds the key window and who owns
//                                   the menu bar: every 50 ms for 30 s by default, prints each
//                                   change of the front process (kosmos_front_pid), the key
//                                   focus process (kosmos_key_focus_pid) and NSWorkspace's
//                                   menuBarOwningApplication, with each app's name and
//                                   activation policy, then the time each read took. Passive:
//                                   open Raycast, Spotlight, a password prompt, Control Center
//                                   or a menu, or focus an empty workspace in Kosmos, while it
//                                   runs to see which read names what.
//   kosmos-probe events [seconds]   Which SkyLight events reach Kosmos, and when: prints each
//                                   event Kosmos registers, with the wall clock time the
//                                   unified log uses, the window and its app, for 30 s by
//                                   default. Every window is watched on the probe's own
//                                   connection. Passive: it opens no window and takes no
//                                   focus, so it runs beside Kosmos while switches are timed.
//   kosmos-probe mission-control [seconds]
//                                   Which Mission Control signals arrive (MissionControl.swift).
//   kosmos-probe bench-windows <count> [display] | eui [pid...]
//                                   What script/bench-relayout.sh uses (Bench.swift).
//   kosmos-probe borders | borders-cpu [relayouts]
//                                   What Kosmos's border windows need and cost (Borders.swift).
import AppKit
import CKosmos
import KosmosCore
import KosmosIPC
import KosmosRecovery
import KosmosSkyLight

setvbuf(stdout, nil, _IOLBF, 0)
let arguments = CommandLine.arguments.dropFirst()

switch arguments.first {
case "panel": showPanel()
case "barrier": barrier(cycles: arguments.dropFirst().first.flatMap(Int.init) ?? 50)
case "survive-kill": surviveKill()
case "bar": bar()
case "destroyed-space": destroyedSpace()
case "gone-space-recovery": goneSpaceRecovery()
case "fullscreen-window": fullscreenWindow()
case "fullscreen": fullscreen()
case "departures-window": departuresWindow()
case "departures": departures()
case "tabs-window": tabsWindow()
case "tabs": tabs(conceal: arguments.dropFirst().first)
case "hidden-window": showHiddenWindow(levels: arguments.dropFirst().first == "levels")
case "reveal": reveal()
case "displays": displays()
case "secure-input": secureInput()
case "ax-child": axChild()
case "ax-timeout": axTimeout()
case "key-stub": keyStub(arguments.dropFirst().first ?? "S", Array(arguments.dropFirst(2)))
case "keying": keying(rounds: arguments.dropFirst().first.flatMap(Int.init) ?? 3, finder: arguments.contains("finder"))
case "level": levels()
case "events": events(seconds: arguments.dropFirst().first.flatMap(Double.init) ?? 30)
case "key-holder": keyHolder(seconds: arguments.dropFirst().first.flatMap(Double.init) ?? 30)
case "holding": holding()
case "mission-control": missionControl(seconds: arguments.dropFirst().first.flatMap(Double.init) ?? 120)
case "bench-windows" where arguments.count >= 2 && Int(arguments.dropFirst().first!) != nil:
    benchWindows(Int(arguments.dropFirst().first!)!, on: arguments.dropFirst(2).first)
case "eui": enhancedUserInterface(arguments.dropFirst().compactMap { pid_t($0) })
case "borders": borders()
case "borders-cpu": bordersCPU(relayouts: arguments.dropFirst().first.flatMap(Int.init) ?? 12)
case "border-targets" where arguments.count >= 2 && Int(arguments.dropFirst().first!) != nil:
    borderTargets(Int(arguments.dropFirst().first!)!)
default:
    print("usage: kosmos-probe barrier [cycles] | survive-kill | bar | destroyed-space | gone-space-recovery | fullscreen | departures | tabs [strip|keep] | reveal | displays | secure-input | ax-timeout | keying [rounds] [finder] | level [onscreen|opaque] | events [seconds] | key-holder [seconds] | mission-control [seconds] | holding | bench-windows <count> [display] | eui [pid...] | borders | borders-cpu [relayouts]")
    exit(2)
}

func bar() {
    func payload(_ arguments: [String]) -> [CChar] { arguments.flatMap { $0.utf8CString } + [0] }
    let query = payload(["--query", "bar"])
    var reply = [CChar](repeating: 0, count: 8192)
    var start = ContinuousClock.now
    let count = query.withUnsafeBufferPointer {
        kosmos_bar_query("git.felix.sketchybar", $0.baseAddress, UInt32($0.count), &reply, UInt32(reply.count), 500)
    }
    print(String(format: "--query bar: %d bytes in %.3f ms", count, elapsed(start)))
    if count > 0 { print(String(decoding: reply.prefix(Int(count)).prefix(160).map { UInt8(bitPattern: $0) }, as: UTF8.self)) }

    let state = #"{"workspace":"1","windows":[]}"#
    let trigger = payload(["--trigger", "kosmos_probe", "STATE=" + state])
    var times: [Double] = []
    for _ in 0..<50 {
        start = .now
        let result = trigger.withUnsafeBufferPointer { kosmos_bar_send("git.felix.sketchybar", $0.baseAddress, UInt32($0.count)) }
        times.append(elapsed(start))
        if result != KERN_SUCCESS { print("send failed: \(result)"); return }
        Thread.sleep(forTimeInterval: 0.005)
    }
    print(String(format: "trigger send: median %.4f ms, p95 %.4f ms (first includes the lookup: %.3f ms)",
                 percentile(Array(times.dropFirst()), 0.5), percentile(Array(times.dropFirst()), 0.95), times[0]))
}

@MainActor func goneSpaceRecovery() {
    _ = NSApplication.shared
    let space = kosmos_holding_create()
    guard space != 0 else { print("holding Space not created"); return }
    kosmos_space_destroy(space)
    _ = kosmos_barrier(space)
    let url = FileManager.default.temporaryDirectory.appending(path: "kosmos-gone-\(getpid()).record")
    defer { try? FileManager.default.removeItem(at: url) }
    let file = try! RecordFile(url: url)
    file.publish(RecoveryRecord(windowServer: ProcessIdentity.windowServer()!, manager: .current, spaces: [space]))
    let start = ContinuousClock.now
    let outcome = Recovery.run(file: file)
    print("recovery of a record naming destroyed Space \(space): \(outcome) in \(String(format: "%.0f", elapsed(start))) ms; record cleared: \(file.read() == nil)")
}

@MainActor func displays() {
    let active = DisplayIdentity.active(), managed = DisplayIdentity.managed()
    print("managed displays (SLSCopyManagedDisplays), \(managed.count) for \(active.count) active: \(managed)")
    let sketchyBar = sketchyBarNumbers()
    for id in active {
        let screen = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }
        let uuid = DisplayIdentity.uuid(of: id)
        let number = BarSnapshot.displayNumber(uuid: uuid, active: active.count, managed: managed)
        let start = ContinuousClock.now
        let serial = DisplayIdentity.serial(of: id)
        let readTime = elapsed(start)
        let info = CoreDisplay_DisplayCreateInfoDictionary(id)?.takeRetainedValue() as? [String: Any] ?? [:]
        print("display \(id): bar number \(number), SketchyBar says \(sketchyBar.map { $0[id].map(String.init) ?? "none" } ?? "(no answer)")")
        print("  name '\(screen?.localizedName ?? "no NSScreen")', built-in \(CGDisplayIsBuiltin(id) != 0), main now \(screen != nil && screen == NSScreen.main), bounds \(CGDisplayBounds(id))")
        print("  vendor \(CGDisplayVendorNumber(id)), model \(CGDisplayModelNumber(id)), numeric serial \(CGDisplaySerialNumber(id)), uuid \(uuid ?? "none")")
        print(String(format: "  EDID serial %@ (read in %.3f ms)", serial.map { "'\($0)'" } ?? "none", readTime))
        print("  framebuffer \(info["IODisplayLocation"].map { "\($0)" } ?? "none")")
        print("  CoreDisplay DisplaySerialString \(info["DisplaySerialString"].map { "\($0)" } ?? "none")")
    }
    // Displays that share a UUID share a bar number and a current Space in Kosmos.
    let shared = Dictionary(grouping: active) { DisplayIdentity.uuid(of: $0) ?? "none" }.filter { $0.value.count > 1 }
    if shared.isEmpty { print("display UUIDs: \(active.count) distinct") }
    for (uuid, ids) in shared { print("display UUID \(uuid) is shared by displays \(ids): Kosmos would merge them") }
    // The Space a reveal on each display lands in (docs/hiding.md).
    let spaces = Displays.current()
    for display in spaces.displays {
        print("managed display \(display.identifier): current Space \(display.currentSpace.map(String.init) ?? "not ordinary"), ordinary Spaces \(display.ordinarySpaces)")
    }
    for id in active {
        print("display \(id): a reveal there lands in Space \(spaces.ordinarySpace(on: id, original: nil).map(String.init) ?? "none")")
    }
    // Kosmos's own view: each display by bar number, and the workspace it shows.
    let state = try? IPCClient.send(["state"], socketPath: kosmosSocketPath())
    guard let snapshot = state.flatMap({ try? JSONDecoder().decode(BarSnapshot.self, from: Data($0.stdout.utf8)) }) else {
        return print("Kosmos: no answer to kosmos state")
    }
    print("Kosmos: profile \(snapshot.profile ?? "base")")
    for display in snapshot.displays {
        let shown = snapshot.workspaces.filter { $0.display == display.id && $0.shown }.map(\.name)
        let focused = snapshot.workspaces.contains { $0.display == display.id && $0.focused } ? ", focused" : ""
        print("Kosmos: bar number \(display.id) '\(display.name)' shows \(shown.isEmpty ? "no workspace" : shown.joined(separator: " "))\(focused)")
    }
}

/// SketchyBar's arrangement id for each display, from `--query displays`, or nil when no bar
/// answers or the reply does not parse.
func sketchyBarNumbers() -> [UInt32: Int]? {
    let query: [CChar] = ["--query", "displays"].flatMap { $0.utf8CString } + [0]
    var reply = [CChar](repeating: 0, count: 16384)
    let count = query.withUnsafeBufferPointer {
        kosmos_bar_query("git.felix.sketchybar", $0.baseAddress, UInt32($0.count), &reply, UInt32(reply.count), 500)
    }
    guard count > 0 else { return nil }
    let data = Data(reply.prefix(Int(count)).prefix { $0 != 0 }.map { UInt8(bitPattern: $0) })
    guard let displays = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
    return Dictionary(displays.compactMap { display in
        guard let id = display["DirectDisplayID"] as? Int, let number = display["arrangement-id"] as? Int else { return nil }
        return (UInt32(id), number)
    }, uniquingKeysWith: { first, _ in first })
}

/// An accessory app with no window. Each number on stdin hangs its main thread for that many
/// seconds, then it prints "awake". Prints "ready" once its run loop runs.
@MainActor func axChild() -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    Thread.detachNewThread {
        while let line = readLine() {
            guard let seconds = Double(line) else { continue }
            DispatchQueue.main.async {
                Thread.sleep(forTimeInterval: seconds)
                print("awake")
            }
        }
        exit(0)
    }
    DispatchQueue.main.async { print("ready") }
    app.run()
    exit(0)
}

func axTimeout() {
    guard AXIsProcessTrusted() else { print("this terminal needs Accessibility permission"); exit(1) }
    let child = Process()
    child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    child.arguments = ["ax-child"]
    let input = Pipe(), output = Pipe()
    child.standardInput = input
    child.standardOutput = output
    func line() -> String {
        var bytes = Data()
        while true {
            let byte = output.fileHandleForReading.readData(ofLength: 1)
            if byte.isEmpty || byte == Data("\n".utf8) { return String(decoding: bytes, as: UTF8.self) }
            bytes.append(byte)
        }
    }
    func hang(_ seconds: Double) { input.fileHandleForWriting.write(Data("\(seconds)\n".utf8)) }
    func read(_ element: AXUIElement) -> (AXError, Double) {
        var value: CFTypeRef?
        let start = ContinuousClock.now
        let result = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value)
        return (result, elapsed(start))
    }
    func show(_ result: (AXError, Double)) -> String { String(format: "error %d in %.1f ms", result.0.rawValue, result.1) }
    let systemWide = AXUIElementCreateSystemWide()

    // Launching: read from the moment of the spawn until the child answers.
    let spawned = ContinuousClock.now
    try! child.run()
    defer { child.terminate() }
    let pid = child.processIdentifier
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 1.0)
    var failures: [Int32: Int] = [:]
    var slowest = 0.0
    var answered: Double?
    while elapsed(spawned) < 5000 {
        let result = read(app)
        if result.0 == .success { answered = elapsed(spawned); break }
        failures[result.0.rawValue, default: 0] += 1
        slowest = max(slowest, result.1)
        usleep(5000)
    }
    print("launching: failures by error \(failures.sorted { $0.key < $1.key }), slowest failure \(String(format: "%.1f", slowest)) ms, first answer \(answered.map { String(format: "%.0f ms", $0) } ?? "none") after spawn")
    _ = line()   // ready

    var times = (0..<20).map { _ in read(app).1 }
    print(String(format: "answering: read median %.3f ms, max %.3f ms", percentile(times, 0.5), percentile(times, 1)))

    // Hung: one read with no timeout set anywhere, then one per element timeout.
    hang(4)
    usleep(100_000)
    print("hung, no timeout set: \(show(read(AXUIElementCreateApplication(pid))))")
    for timeout: Float in [0.05, 0.25, 1.0] {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, timeout)
        print("hung, element timeout \(timeout) s: \(show(read(element)))")
    }
    var observer: AXObserver?
    AXObserverCreate(pid, { _, _, _, _ in }, &observer)
    let element = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(element, 0.25)
    var start = ContinuousClock.now
    let added = AXObserverAddNotification(observer!, element, kAXFocusedWindowChangedNotification as CFString, nil)
    print(String(format: "hung, add observer notification, element timeout 0.25 s: error %d in %.1f ms", added.rawValue, elapsed(start)))
    _ = line()   // awake

    // A fresh element takes the system wide timeout.
    hang(3)
    usleep(100_000)
    AXUIElementSetMessagingTimeout(systemWide, 0.25)
    print("hung, fresh element, system wide timeout 0.25 s: \(show(read(AXUIElementCreateApplication(pid))))")
    AXUIElementSetMessagingTimeout(systemWide, 0)
    print("hung, fresh element, system wide timeout reset with 0: \(show(read(AXUIElementCreateApplication(pid))))")
    _ = line()

    // Requests that timed out still wait in the app's queue: time the first answer after a
    // hang during which 10 probes gave up.
    hang(1.5)
    usleep(100_000)
    let prober = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(prober, 0.05)
    for _ in 0..<10 { _ = read(prober) }
    _ = line()
    start = ContinuousClock.now
    let after = read(app)
    print("after a hang with 10 abandoned requests: \(show(after)); \(String(format: "%.1f", elapsed(start))) ms")
    times = (0..<20).map { _ in read(app).1 }
    print(String(format: "answering again: read median %.3f ms", percentile(times, 0.5)))
}

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
    let process: Process
    /// Held open for the stub's lifetime; the stub exits when it closes.
    let input: Pipe
    let output: Pipe
    private var buffer = Data()
    private(set) var windows: [UInt32] = []
    var pid: pid_t { process.processIdentifier }

    init(_ name: String, _ offsets: [String]) {
        self.name = name
        process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["key-stub", name] + offsets
        input = Pipe()
        output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try! process.run()
        windows = line().split(whereSeparator: \.isWhitespace).compactMap { UInt32($0) }
    }

    func line() -> String {
        while !buffer.contains(UInt8(ascii: "\n")) {
            let chunk = output.fileHandleForReading.availableData
            guard !chunk.isEmpty else { print("stub \(name) exited"); exit(1) }
            buffer.append(chunk)
        }
        let end = buffer.firstIndex(of: UInt8(ascii: "\n"))!
        let text = String(decoding: buffer[buffer.startIndex..<end], as: UTF8.self)
        buffer.removeSubrange(buffer.startIndex...end)
        return text
    }

    /// Activates the app from its own background thread. Returns what `activate` returned.
    func activateItself() -> Bool {
        input.fileHandleForWriting.write(Data("activate\n".utf8))
        return line() == "true"
    }

    /// Opens an InvisibleWindow in the stub and returns its id.
    func openInvisibleWindow() -> UInt32 {
        input.fileHandleForWriting.write(Data("invisible\n".utf8))
        return UInt32(line()) ?? 0
    }

    /// Keys a window of the stub's own by the private path, from the stub's background thread.
    func keyOwnWindow(_ id: UInt32) -> Bool {
        input.fileHandleForWriting.write(Data("key-self \(id)\n".utf8))
        return line() == "true"
    }

    /// Activates another app from the stub's background thread. Returns what the call returned.
    func activate(_ pid: pid_t, _ way: ActivationWay) -> Bool {
        input.fileHandleForWriting.write(Data("activate \(way.rawValue) \(pid)\n".utf8))
        return line() == "true"
    }

    /// The window the app itself holds key, from AppKit, or nil.
    func appKey() -> UInt32? {
        input.fileHandleForWriting.write(Data("key\n".utf8))
        return UInt32(line()).flatMap { $0 == 0 ? nil : $0 }
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
    let rounds = max(rounds, 1)
    _ = NSApplication.shared   // the concealed case's bridged operations need an AppKit client
    guard AXIsProcessTrusted() else { print("this terminal needs Accessibility permission"); exit(1) }
    func wait(_ seconds: Double) { RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds)) }
    // Focus goes back to this app and window at the end.
    let before = NSWorkspace.shared.frontmostApplication?.processIdentifier
    let beforeWindow = before.flatMap(focusedWindow(of:))
    // A1 and A2 overlap, A3 sits apart, and B1 covers parts of A1 and A2.
    let a = KeyStub("A", ["0,0", "60,40", "300,0"])
    let b = KeyStub("B", ["30,20"])
    let notes = FocusNotes()
    notes.watch(a.pid)
    notes.watch(b.pid)
    defer {
        a.process.terminate()
        b.process.terminate()
        if let before, let beforeWindow { _ = kosmos_make_key(before, beforeWindow) }
    }
    wait(0.5)

    enum Order: String, CaseIterable {
        case recordOnly = "record only"
        case raiseFirst = "AXRaise, then record"
        case raiseAfter = "record, then AXRaise"
        /// As the worker's raise after the key record: only while the app is front and the
        /// target is its focused window, read just after the record.
        case postRaise = "record, then AXRaise while front and focused"
        case raiseOnly = "AXRaise alone"
    }
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
                // Kosmos's order sets up each case; a case whose setup did not key is skipped.
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

    // An accessory app in the background activating itself, as Kosmos does for an empty
    // workspace on the public path.
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

    // A background app with no window, as Kosmos is, activating another app: the public path
    // does that for every target. Then the private front with no key window, which the
    // private path uses for an empty workspace. B is front before each try.
    let s = KeyStub("S", [])
    defer { s.process.terminate() }
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

    // Kosmos keying a window of its own for an empty workspace: S's invisible window, keyed
    // by the private path from S's own background thread and from another process. B is
    // front before each try.
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

    // A key window concealed in a holding Space and revealed again, as a switch away and back
    // does. The focus queue skips a request when the app is front and names the target as
    // focused; it would skip wrongly if the app named it while holding no key window.
    var wrongSkips = 0, concealTrials = 0, rekeyed = 0
    var concealedKeys: [String: Int] = [:], concealedTries: [String: Int] = [:]
    let space = kosmos_holding_create()
    if let desktop = Displays.current().ordinarySpace(original: nil), space != 0 {
        var ids = [a.windows[0]]
        defer {
            var every = a.windows
            kosmos_remove_windows(space, &every, every.count)
            kosmos_space_destroy(space)
        }
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

        // An app whose every window is concealed, fronted as an empty workspace fronts Finder,
        // by S's activate and by the private front with no key window: whether it keys a
        // concealed window, with the windows kept in their ordinary Space or not. B is front
        // before each try.
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
    } else {
        if space != 0 { kosmos_space_destroy(space) }
        print("no holding Space or no ordinary Space; the concealed cases did not run")
    }

    print("\nsummary: a hit keys the target window in the app that holds it; a miss leaves another window key")
    for test in cases {
        for order in Order.allCases {
            let row = "\(test.name) | \(order.rawValue)"
            let hit = hits[row] ?? 0, runs = trials[row] ?? 0
            print("  \(row): \(hit) hits, \(runs - hit) misses, on top \(raised[row] ?? 0) of \(runs)")
        }
    }
    print("  a background accessory app activating itself became front in \(selfActivated) of \(selfTrials)")
    for row in tries.keys.sorted() {
        print("  \(row): front in \(fronted[row] ?? 0) of \(tries[row] ?? 0)")
    }
    for way in ownWays {
        print("  \(way.label): S front with it key in \(ownKeyed[way.label] ?? 0) of \(ownTries[way.label] ?? 0)")
    }
    print("  concealed and revealed: the already key check skipped wrongly in \(wrongSkips) of \(concealTrials); "
          + "Kosmos's order keyed A1 again in \(rekeyed) of \(concealTrials)")
    for row in concealedTries.keys.sorted() {
        print("  \(row): A keyed a concealed window in \(concealedKeys[row] ?? 0) of \(concealedTries[row] ?? 0)")
    }
    if !raiseTimes.isEmpty {
        print(String(format: "  AXRaise: median %.2f ms, max %.2f ms over %d raises", percentile(raiseTimes, 0.5), percentile(raiseTimes, 1), raiseTimes.count))
    }
}

nonisolated(unsafe) var levelEvents: [(id: UInt32, at: Double, payload: [UInt8])] = []
/// Each change: when the child asked for it, and when WindowServer first read the new level.
nonisolated(unsafe) var levelSteps: [(at: Double, landed: Double, text: String)] = []

@MainActor func levels() -> Never {
    // SkyLight delivers events inside a running AppKit event loop, as in Kosmos.
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    // The switch at the top runs before main.swift's globals below it are initialized.
    levelEvents = []
    levelSteps = []
    let start = uptime()
    // Registered before the child starts, so the window's creation shows too. In the reverse
    // engineered CGSInternal headers, the ids below 750 include input events, which the probe
    // leaves alone.
    let ids: Range<UInt32> = 750..<1800
    var registered = 0
    for id in ids {
        let result = SLSRegisterConnectionNotifyProc(SLSMainConnectionID(), { id, data, length, _, _ in
            let at = uptime()
            let payload = data == nil ? [] : [UInt8](UnsafeRawBufferPointer(start: data, count: length))
            DispatchQueue.main.async { levelEvents.append((id, at, payload)) }
        }, id, nil)
        if result == .success { registered += 1 }
    }
    let child = Process()
    child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    child.arguments = ["hidden-window", "levels"] + CommandLine.arguments.dropFirst(2)
    let pipe = Pipe()
    child.standardOutput = pipe
    try! child.run()
    var line = Data()
    while !line.contains(UInt8(ascii: "\n")) { line.append(pipe.fileHandleForReading.availableData) }
    let window = UInt32(String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))!
    var watched = [window]
    SLSRequestNotificationsForWindows(SLSMainConnectionID(), &watched, 1)
    print("window \(window), pid \(child.processIdentifier); \(registered) of \(ids.count) notifications registered")
    pipe.fileHandleForReading.readabilityHandler = { handle in
        let data = handle.availableData
        guard !data.isEmpty else { handle.readabilityHandler = nil; return }
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let fields = line.split(separator: " ")   // "<uptime> level <level>"
            guard fields.count == 3, let at = Double(fields[0]), let level = Int32(fields[2]) else { continue }
            // AppKit sends the level to WindowServer after the setter returns.
            var landed: Double?
            while landed == nil, uptime() - at < 500 {
                if SkyLight.rows([window]).first?.level == level { landed = uptime() } else { usleep(500) }
            }
            let text = "child sets level \(level); WindowServer reads it "
                + (landed.map { String(format: "%.1f ms later", $0 - at) } ?? "not within 500 ms")
            let step = (at: at, landed: landed ?? at, text: text)
            DispatchQueue.main.async { levelSteps.append(step) }
        }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
        reportLevels(window, start: start)
        exit(0)
    }
    app.run()
    exit(0)
}

/// The events that name the window, in time order with the level changes, then the events
/// of other ids that came from a change's request to 100 ms after WindowServer read it,
/// against how many came at other times.
@MainActor func reportLevels(_ window: UInt32, start: Double) {
    var timeline = levelSteps.map { (at: $0.at, text: $0.text) }
    var others: [(id: UInt32, at: Double)] = []
    for event in levelEvents {
        let offsets = stride(from: 0, to: event.payload.count - 3, by: 4).filter { offset in
            event.payload.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) } == window
        }
        let bytes = event.payload.prefix(32).map { String(format: "%02x", $0) }.joined()
        guard !offsets.isEmpty else {
            others.append((event.id, event.at))
            timeline.append((event.at, "  event \(event.id), not naming the window, payload \(bytes)"))
            continue
        }
        timeline.append((event.at, "event \(event.id), \(event.payload.count) bytes, window id at offset \(offsets), payload \(bytes)"))
    }
    for entry in timeline.sorted(by: { $0.at < $1.at }) { print(String(format: "%8.1f ms ", entry.at - start) + entry.text) }
    print("events of other ids, by whether they came from a request to 100 ms after WindowServer read the level (\(levelSteps.count) changes):")
    for (id, events) in Dictionary(grouping: others, by: \.id).sorted(by: { $0.key < $1.key }) {
        let near = events.filter { event in levelSteps.contains { event.at >= $0.at && event.at <= $0.landed + 100 } }.count
        print("  event \(id): \(near) near a change, \(events.count - near) at other times")
    }
    if others.isEmpty { print("  none") }
}

@MainActor func events(seconds: Double) -> Never {
    // SkyLight delivers events inside a running AppKit event loop, as in Kosmos.
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    // The switch at the top runs before main.swift's globals below it are initialized.
    eventAppNames = [:]
    eventTime = DateFormatter()
    eventTime.dateFormat = "HH:mm:ss.SSS"
    for id in WindowServerEvent.ids {
        _ = SLSRegisterConnectionNotifyProc(SLSMainConnectionID(), { id, data, length, _, _ in
            let at = Date()
            let bytes = UnsafeRawBufferPointer(start: data, count: data == nil ? 0 : length)
            let payload = bytes.prefix(16).map { String(format: "%02x", $0) }.joined()
            let window = WindowServerEvent(id: id, payload: bytes)?.window
            DispatchQueue.main.async { MainActor.assumeIsolated { printEvent(id, window: window, payload: payload, at: at) } }
        }, id, nil)
    }
    var watched = SkyLight.allWindowIDs()
    SLSRequestNotificationsForWindows(SLSMainConnectionID(), &watched, Int32(watched.count))
    print("watching \(watched.count) windows for \(seconds) s")
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exit(0) }
    app.run()
    exit(0)
}

/// Each app's name by pid, read once. Main thread only.
nonisolated(unsafe) var eventAppNames: [pid_t: String] = [:]
nonisolated(unsafe) var eventTime = DateFormatter()

@MainActor func printEvent(_ id: UInt32, window: UInt32?, payload: String, at: Date) {
    var line = "\(eventTime.string(from: at)) \(id)"
    if let window {
        let pid = SkyLight.rows([window]).first?.pid
        let name = pid.map { pid in
            if let name = eventAppNames[pid] { return name }
            let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
            eventAppNames[pid] = name
            return name
        } ?? "gone"
        line += " window \(window) (\(name))"
    } else {
        line += " payload \(payload)"
    }
    print(line)
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
