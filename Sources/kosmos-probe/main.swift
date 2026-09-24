// Probes for private behaviour the design depends on. Each probe touches only windows it
// creates itself.
//
//   kosmos-probe barrier [cycles]   Does one bridged read return only after earlier
//                                   conceal and reveal operations have landed?
//   kosmos-probe bar                Checks SketchyBar's wire format with a read-only query,
//                                   and times sends of an event no item subscribes to.
//   kosmos-probe destroyed-space    What reading a destroyed Space's members returns: nil (a
//                                   failed read) or an empty list.
//   kosmos-probe gone-space-recovery  Recovery of a record that names a destroyed Space, as
//                                   a crash between destroying and clearing would leave it.
//   kosmos-probe survive-kill       Conceals a panel with the guardian armed, then kills
//                                   itself with SIGKILL. Check afterwards that the panel
//                                   is back, the Space is gone and the record is clear.
//   kosmos-probe reveal             Does an exclusive add to an ordinary Space take a window
//                                   out of the holding Space, and where does a window
//                                   removed from its only Space land? Its window is
//                                   invisible, off every display, in an app with the
//                                   prohibited activation policy, so it runs beside a live
//                                   session: the panel's regular app, and an accessory one,
//                                   made itself the front process when it started and took
//                                   the key window from the user's app for the second the
//                                   probe ran (WindowServer log, 2026-09-24).
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
//   kosmos-probe keying [rounds]    Keys windows of two stub apps three ways: the key record
//                                   alone, AXRaise then the record (the order Kosmos uses), and
//                                   the record then AXRaise (yabai and alt-tab). Covers two
//                                   stacked windows of one app, two side by side, another app,
//                                   and back into an app whose other window was key. The stubs
//                                   are accessory apps with small windows at the bottom right,
//                                   which a running Kosmos leaves alone. The probe takes
//                                   keyboard focus while it runs and hands it back at the end.
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
case "hidden-window": showHiddenWindow()
case "reveal": reveal()
case "displays": displays()
case "secure-input": secureInput()
case "ax-child": axChild()
case "ax-timeout": axTimeout()
case "key-stub": keyStub(arguments.dropFirst().first ?? "S", Array(arguments.dropFirst(2)))
case "keying": keying(rounds: arguments.dropFirst().first.flatMap(Int.init) ?? 3)
default:
    print("usage: kosmos-probe barrier [cycles] | survive-kill | bar | destroyed-space | gone-space-recovery | reveal | displays | secure-input | ax-timeout | keying [rounds]")
    exit(2)
}

/// A panel in a child process, so the probe acts on another app's window, as Kosmos does.
/// Prints its window id and stays until killed.
@MainActor func showPanel() -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let panel = NSPanel(contentRect: NSRect(x: 20, y: 20, width: 200, height: 100),
                        styleMask: [.titled, .utilityWindow], backing: .buffered, defer: false)
    panel.title = "kosmos-probe"
    panel.hidesOnDeactivate = false
    panel.orderFrontRegardless()
    print(panel.windowNumber)
    app.run()
    exit(0)
}

/// An invisible window off every display, in an app that can never be the front process.
/// Prints its window id and stays until killed.
@MainActor func showHiddenWindow() -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 60, height: 60),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.alphaValue = 0
    window.ignoresMouseEvents = true
    window.orderFrontRegardless()
    print(window.windowNumber)
    app.run()
    exit(0)
}

/// Runs `command` (`panel` or `hidden-window`) in a child process and returns its window.
func spawnPanel(_ command: String = "panel") -> (Process, UInt32) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    process.arguments = [command]
    let pipe = Pipe()
    process.standardOutput = pipe
    try! process.run()
    var line = Data()
    while !line.contains(UInt8(ascii: "\n")) { line.append(pipe.fileHandleForReading.availableData) }
    let id = UInt32(String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))!
    Thread.sleep(forTimeInterval: 0.3)   // let the panel reach the screen
    return (process, id)
}

func inSpace(_ window: UInt32, _ space: UInt64) -> Bool {
    let windows = kosmos_space_windows(space) as? [UInt32] ?? []
    return windows.contains(window)
}

func elapsed(_ start: ContinuousClock.Instant) -> Double {
    let d = ContinuousClock.now - start
    return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
}

func percentile(_ values: [Double], _ p: Double) -> Double {
    let sorted = values.sorted()
    return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
}

func barrier(cycles: Int) {
    let (panel, window) = spawnPanel()
    let start = ContinuousClock.now
    let space = kosmos_holding_create()
    guard space != 0 else { print("holding Space not created"); panel.terminate(); exit(1) }
    print("holding Space \(space) created in \(String(format: "%.2f", elapsed(start))) ms, panel window \(window)")
    defer {
        var ids = [window]
        _ = kosmos_remove_windows(space, &ids, 1)
        _ = kosmos_space_destroy(space)
        panel.terminate()
    }

    var ids = [window]
    for useBarrier in [false, true] {
        var concealed = 0, revealed = 0
        var opTimes: [Double] = [], barrierTimes: [Double] = []
        for _ in 0..<cycles {
            var t = ContinuousClock.now
            _ = kosmos_add_windows(space, &ids, 1, false)
            opTimes.append(elapsed(t))
            if useBarrier { t = .now; _ = kosmos_barrier(space); barrierTimes.append(elapsed(t)) }
            if inSpace(window, space) { concealed += 1 }
            Thread.sleep(forTimeInterval: 0.02)

            t = .now
            _ = kosmos_remove_windows(space, &ids, 1)
            opTimes.append(elapsed(t))
            if useBarrier { t = .now; _ = kosmos_barrier(space); barrierTimes.append(elapsed(t)) }
            if !inSpace(window, space) { revealed += 1 }
            Thread.sleep(forTimeInterval: 0.02)
        }
        print(useBarrier ? "with barrier:" : "without barrier (control):")
        print("  conceal landed at first check \(concealed)/\(cycles), reveal \(revealed)/\(cycles)")
        print(String(format: "  operation submit median %.3f ms, p95 %.3f ms", percentile(opTimes, 0.5), percentile(opTimes, 0.95)))
        if useBarrier {
            print(String(format: "  barrier read median %.3f ms, p95 %.3f ms, max %.3f ms",
                         percentile(barrierTimes, 0.5), percentile(barrierTimes, 0.95), percentile(barrierTimes, 1)))
        }
    }
}

func surviveKill() -> Never {
    guard let lock = try? FileLock(KosmosFiles.lock) else { print("Kosmos is running; quit it first"); exit(1) }
    let file = try! RecordFile(url: KosmosFiles.record)
    guard case .nothingRecorded = Recovery.run(file: file) else { print("a previous record needed recovery; run again"); exit(1) }

    let (panel, window) = spawnPanel()
    print("panel pid \(panel.processIdentifier) window \(window)")
    let guardian = Process()
    guardian.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appending(path: "kosmos-guardian")
    guardian.arguments = ["watch", String(getpid())]
    let ready = Pipe()
    guardian.standardOutput = ready
    try! guardian.run()
    guard ready.fileHandleForReading.readData(ofLength: 1) == Data("R".utf8) else { print("guardian not ready"); exit(1) }
    print("guardian \(guardian.processIdentifier) ready, process group \(getpgid(guardian.processIdentifier)) (mine \(getpgrp()))")

    // The record names the Space before any window enters it, and the window before its first hide.
    var record = RecoveryRecord(windowServer: ProcessIdentity.windowServer()!, manager: .current)
    let space = kosmos_holding_create()
    record.spaces = [space]
    let original = (kosmos_window_spaces(window) as? [UInt64])?.first ?? 0
    record.windows = [.init(id: window, owner: ProcessIdentity.of(panel.processIdentifier)!, originalSpace: original)]
    file.publish(record)

    var ids = [window]
    kosmos_add_windows(space, &ids, 1, false)
    _ = kosmos_barrier(space)
    print("panel concealed in Space \(space): \(inSpace(window, space)); killing myself")
    withExtendedLifetime(lock) {}
    kill(getpid(), SIGKILL)
    exit(1)
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

@MainActor func destroyedSpace() {
    _ = NSApplication.shared   // bridged operations need an AppKit client
    let space = kosmos_holding_create()
    guard space != 0 else { print("holding Space not created"); return }
    let before = kosmos_space_windows(space) as? [UInt32]
    print("live Space \(space): members \(before.map { "\($0)" } ?? "nil (read failed)")")
    _ = kosmos_space_destroy(space)
    _ = kosmos_barrier(space)
    for delay in [0.0, 0.1, 1.0] {
        Thread.sleep(forTimeInterval: delay)
        let after = kosmos_space_windows(space) as? [UInt32]
        print("after destroy (+\(delay) s): members \(after.map { "\($0)" } ?? "nil (read failed)"), barrier \(kosmos_barrier(space))")
    }
    let never: UInt64 = 0x7fff_ffff_0000
    print("a Space id that never existed: members \((kosmos_space_windows(never) as? [UInt32]).map { "\($0)" } ?? "nil (read failed)")")
}

@MainActor func goneSpaceRecovery() {
    _ = NSApplication.shared
    let space = kosmos_holding_create()
    guard space != 0 else { print("holding Space not created"); return }
    _ = kosmos_space_destroy(space)
    _ = kosmos_barrier(space)
    let url = FileManager.default.temporaryDirectory.appending(path: "kosmos-gone-\(getpid()).record")
    defer { try? FileManager.default.removeItem(at: url) }
    let file = try! RecordFile(url: url)
    file.publish(RecoveryRecord(windowServer: ProcessIdentity.windowServer()!, manager: .current, spaces: [space]))
    let start = ContinuousClock.now
    let outcome = Recovery.run(file: file)
    print("recovery of a record naming destroyed Space \(space): \(outcome) in \(String(format: "%.0f", elapsed(start))) ms; record cleared: \(file.read() == nil)")
}

@MainActor func reveal() {
    _ = NSApplication.shared   // bridged operations need an AppKit client
    let (child, window) = spawnPanel("hidden-window")
    defer { child.terminate() }
    guard let desktop = Displays.current().ordinarySpace(original: nil) else { print("no ordinary Space"); return }
    let space = kosmos_holding_create()
    guard space != 0 else { print("holding Space not created"); return }
    var ids = [window]
    defer {
        _ = kosmos_remove_windows(space, &ids, 1)
        _ = kosmos_space_destroy(space)
    }
    print("window \(window), ordinary Space \(desktop), holding Space \(space)")
    /// The window's ordinary Spaces and whether the holding Space has it, after one barrier.
    func state(_ step: String) -> (ordinary: [UInt64], held: Bool) {
        _ = kosmos_barrier(space)
        let ordinary = (kosmos_window_spaces(window) as? [UInt64]) ?? [], held = inSpace(window, space)
        print("\(step): ordinary Spaces \(ordinary), in holding \(held)")
        return (ordinary, held)
    }
    let cycles = 3
    var addOnly = 0, addThenRemove = 0
    for cycle in 1...cycles {
        kosmos_add_windows(space, &ids, 1, true)
        _ = state("\(cycle) strip (exclusive add to the holding Space)")
        kosmos_add_windows(desktop, &ids, 1, true)
        if state("\(cycle)   exclusive add to \(desktop)").held {
            Thread.sleep(forTimeInterval: 0.2)
            if state("\(cycle)   0.2 s later").held { addOnly += 1 }
        }
        kosmos_remove_windows(space, &ids, 1)
        let revealed = state("\(cycle)   then removal from the holding Space")
        if revealed.ordinary == [desktop] && !revealed.held { addThenRemove += 1 }
    }
    kosmos_add_windows(space, &ids, 1, true)
    _ = state("strip")
    kosmos_remove_windows(space, &ids, 1)
    let landed = state("removal alone")
    print("the exclusive add left the window in the holding Space in \(addOnly) of \(cycles) cycles; "
          + "the add then the removal revealed it on \(desktop) in \(addThenRemove) of \(cycles); "
          + "removed from its only Space, it landed on \(landed.ordinary)")
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
    // Kosmos fixes the display it tiles at its own launch, which NSScreen.main now may not match.
    let state = try? IPCClient.send(["state"], socketPath: kosmosSocketPath())
    let tiled = state.flatMap { try? JSONDecoder().decode(BarSnapshot.self, from: Data($0.stdout.utf8)) }?.displays.first
    print("Kosmos tiles \(tiled.map { "bar number \($0.id), '\($0.name)'" } ?? "(no answer)") (kosmos state)")
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
/// visible area, prints the window ids, and exits when its standard input closes.
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
        while !FileHandle.standardInput.availableData.isEmpty {}
        exit(0)
    }
    app.run()
    exit(0)
}

struct KeyStub {
    let name: String
    let process: Process
    /// Held open for the stub's lifetime; the stub exits when it closes.
    let input: Pipe
    let windows: [UInt32]
    var pid: pid_t { process.processIdentifier }
    func label(_ window: UInt32) -> String { windows.firstIndex(of: window).map { "\(name)\($0 + 1)" } ?? String(window) }
}

func launchKeyStub(_ name: String, _ offsets: [String]) -> KeyStub {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    process.arguments = ["key-stub", name] + offsets
    let input = Pipe(), output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    try! process.run()
    var line = Data()
    while !line.contains(UInt8(ascii: "\n")) {
        let chunk = output.fileHandleForReading.availableData
        guard !chunk.isEmpty else { print("stub \(name) exited"); exit(1) }
        line.append(chunk)
    }
    let ids = String(decoding: line, as: UTF8.self).split(whereSeparator: \.isWhitespace).compactMap { UInt32($0) }
    return KeyStub(name: name, process: process, input: input, windows: ids)
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

/// The app's focused window, which is the key window while the app is frontmost.
func focusedWindow(of pid: pid_t) -> UInt32? {
    var focused: CFTypeRef?
    var id: UInt32 = 0
    guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute as CFString, &focused) == .success,
          let focused, _AXUIElementGetWindow((focused as! AXUIElement), &id) == .success else { return nil }
    return id
}

@MainActor func keying(rounds: Int) {
    _ = NSApplication.shared
    guard AXIsProcessTrusted() else { print("this terminal needs Accessibility permission"); exit(1) }
    func wait(_ seconds: Double) { RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds)) }
    // Focus goes back to this app and window at the end.
    let before = NSWorkspace.shared.frontmostApplication?.processIdentifier
    let beforeWindow = before.flatMap(focusedWindow(of:))
    // A1 and A2 overlap, A3 sits apart, and B1 covers parts of A1 and A2.
    let a = launchKeyStub("A", ["0,0", "60,40", "300,0"])
    let b = launchKeyStub("B", ["30,20"])
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
    }
    var raiseTimes: [Double] = []
    func focus(_ stub: KeyStub, _ window: UInt32, _ order: Order) {
        func raise() {
            guard let element = windowElement(stub.pid, window) else { return print("  no element for \(stub.label(window))") }
            let start = ContinuousClock.now
            _ = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
            raiseTimes.append(elapsed(start))
        }
        if order == .raiseFirst { raise() }
        if !kosmos_make_key(stub.pid, window) { print("  kosmos_make_key failed for \(stub.label(window))") }
        if order == .raiseAfter { raise() }
        wait(0.3)
    }
    func onTop(_ window: UInt32, over others: [UInt32]) -> Bool {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let order = list.compactMap { ($0[kCGWindowNumber as String] as? Int).map(UInt32.init) }
        guard let index = order.firstIndex(of: window) else { return false }
        return others.allSatisfy { (order.firstIndex(of: $0) ?? .max) > index }
    }

    typealias Target = (stub: KeyStub, window: UInt32)
    let cases: [(name: String, setup: [Target], target: Target, covers: [UInt32])] = [
        ("same app, stacked: A2 key, then A1", [(a, a.windows[1])], (a, a.windows[0]), [a.windows[1]]),
        ("same app, side by side: A1 key, then A3", [(a, a.windows[0])], (a, a.windows[2]), []),
        ("other app: A1 key, then B1", [(a, a.windows[0])], (b, b.windows[0]), [a.windows[0], a.windows[1]]),
        ("back into A after A2 was key: A2, B1, then A1", [(a, a.windows[1]), (b, b.windows[0])], (a, a.windows[0]),
         [a.windows[1], b.windows[0]]),
    ]
    var keyed: [String: Int] = [:], raised: [String: Int] = [:], trials: [String: Int] = [:]
    for round in 1...rounds {
        for test in cases {
            for order in Order.allCases {
                // Kosmos's order sets up each case; a case whose setup did not key is skipped.
                for step in test.setup { focus(step.stub, step.window, .raiseFirst) }
                let last = test.setup.last!
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == last.stub.pid,
                      focusedWindow(of: last.stub.pid) == last.window else {
                    print("round \(round), \(test.name), \(order.rawValue): setup did not key \(last.stub.label(last.window)), skipped")
                    continue
                }
                raiseTimes.removeAll()
                focus(test.target.stub, test.target.window, order)
                let front = NSWorkspace.shared.frontmostApplication?.processIdentifier == test.target.stub.pid
                let key = focusedWindow(of: test.target.stub.pid)
                let isKey = front && key == test.target.window
                let isOnTop = onTop(test.target.window, over: test.covers)
                let row = "\(test.name) | \(order.rawValue)"
                trials[row, default: 0] += 1
                if isKey { keyed[row, default: 0] += 1 }
                if isOnTop { raised[row, default: 0] += 1 }
                let raiseTime = raiseTimes.first.map { String(format: ", AXRaise %.2f ms", $0) } ?? ""
                print("round \(round), \(row): \(isKey ? "keyed" : "NOT KEYED") (front \(front ? "yes" : "no"), "
                      + "focused \(key.map(test.target.stub.label) ?? "none")), \(isOnTop ? "on top" : "not on top")\(raiseTime)")
            }
        }
    }
    print("\nsummary: a hit keys the target window; a miss leaves another window key")
    for test in cases {
        for order in Order.allCases {
            let row = "\(test.name) | \(order.rawValue)"
            let hits = keyed[row] ?? 0, runs = trials[row] ?? 0
            print("  \(row): \(hits) hits, \(runs - hits) misses, on top \(raised[row] ?? 0) of \(runs)")
        }
    }
}
