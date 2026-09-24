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
//   kosmos-probe fullscreen [dry]   Which signals report a window entering and leaving
//                                   native fullscreen, and when: SkyLight Space events, and
//                                   Displays.isFullscreen after each Space membership event,
//                                   as the inventory checks it. dry never enters.
//                                   The window belongs to an accessory app, which Kosmos
//                                   does not manage.
import AppKit
import CKosmos
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
default:
    print("usage: kosmos-probe barrier [cycles] | survive-kill | bar | destroyed-space | gone-space-recovery | fullscreen")
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

func spawnPanel() -> (Process, UInt32) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    process.arguments = ["panel"]
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

/// A window that enters native fullscreen 1.5 s after it appears and leaves 4 s later, in
/// an accessory app. Prints its window id.
@MainActor func fullscreenWindow() -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 420, height: 300),
                          styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
    window.collectionBehavior = [.fullScreenPrimary]
    window.title = "kosmos-probe fullscreen"
    window.makeKeyAndOrderFront(nil)
    app.activate()
    print(window.windowNumber)
    let dry = CommandLine.arguments.contains("dry")
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { print("enter"); if !dry { window.toggleFullScreen(nil) } }
    DispatchQueue.main.asyncAfter(deadline: .now() + 5.5) { print("leave"); if !dry { window.toggleFullScreen(nil) } }
    DispatchQueue.main.asyncAfter(deadline: .now() + 9) { exit(0) }
    app.run()
    exit(0)
}

/// Space types by id, from the managed display Spaces: 0 ordinary, 4 fullscreen.
func spaceTypes() -> [UInt64: Int] {
    let displays = SLSCopyManagedDisplaySpaces(SLSMainConnectionID())?.takeRetainedValue() as? [[String: Any]] ?? []
    var types: [UInt64: Int] = [:]
    for display in displays {
        for space in display["Spaces"] as? [[String: Any]] ?? [] {
            if let id = space["id64"] as? UInt64 { types[id] = space["type"] as? Int ?? -1 }
        }
    }
    return types
}

nonisolated(unsafe) var probeStart = ContinuousClock.now
nonisolated(unsafe) var probeWindow: UInt32 = 0
nonisolated(unsafe) var probeLast = ""

/// The window's Spaces with their types. AXFullScreen was read in runs without an event
/// loop: reading it here, with AppKit running, blocked.
func probeState() -> String {
    let types = spaceTypes()
    let spaces = (kosmos_window_spaces(probeWindow) as? [UInt64] ?? []).map { "\($0):\(types[$0] ?? -1)" }
    return "spaces \(spaces)"
}

@MainActor func fullscreen() -> Never {
    // SkyLight delivers events inside a running AppKit event loop, as in Kosmos.
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let child = Process()
    child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    child.arguments = ["fullscreen-window"] + (CommandLine.arguments.contains("dry") ? ["dry"] : [])
    let pipe = Pipe()
    child.standardOutput = pipe
    try! child.run()
    var line = Data()
    while !line.contains(UInt8(ascii: "\n")) { line.append(pipe.fileHandleForReading.availableData) }
    probeWindow = UInt32(String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))!
    probeStart = .now
    print("window \(probeWindow), pid \(child.processIdentifier), AX trusted \(AXIsProcessTrusted())")
    pipe.fileHandleForReading.readabilityHandler = { handle in
        let text = String(decoding: handle.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { print(String(format: "%7.1f ms child: ", elapsed(probeStart)) + text) }
    }
    for id: UInt32 in [1325, 1326, 1327, 1328, 1401, 806, 807, 808, 815, 816] {
        _ = SLSRegisterConnectionNotifyProc(SLSMainConnectionID(), { id, data, length, _, _ in
            let bytes = UnsafeRawBufferPointer(start: data, count: data == nil ? 0 : length)
            func u32(_ offset: Int) -> UInt32 { bytes.count >= offset + 4 ? bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self) : 0 }
            func u64(_ offset: Int) -> UInt64 { bytes.count >= offset + 8 ? bytes.loadUnaligned(fromByteOffset: offset, as: UInt64.self) : 0 }
            switch id {
            case 1325, 1326:
                guard u32(8) == probeWindow else { return }
                print(String(format: "%7.1f ms event %d space %llu", elapsed(probeStart), id, u64(0)))
                // The check the inventory makes on these events, off the main thread.
                DispatchQueue.global(qos: .userInitiated).async {
                    let state = Displays.isFullscreen(probeWindow).map { "\($0)" } ?? "nil (no Space)"
                    print(String(format: "%7.1f ms   Displays.isFullscreen: ", elapsed(probeStart)) + state)
                }
            case 1327, 1328:
                print(String(format: "%7.1f ms event %d space %llu", elapsed(probeStart), id, u64(0)))
            case 1401:
                print(String(format: "%7.1f ms event 1401", elapsed(probeStart)))
            default:
                guard u32(0) == probeWindow else { return }
                print(String(format: "%7.1f ms event %d", elapsed(probeStart), id))
            }
        }, id, nil)
    }
    var ids = [probeWindow]
    SLSRequestNotificationsForWindows(SLSMainConnectionID(), &ids, 1)
    DispatchQueue.main.asyncAfter(deadline: .now() + 10) { exit(0) }
    app.run()
    exit(0)
}
