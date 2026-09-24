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
//   kosmos-probe displays           Each display's identity as Kosmos reads it: EDID
//                                   serial, framebuffer, and the bar number, checked against
//                                   SketchyBar's own when it runs. Read only. Every
//                                   framebuffer and the EDID fields it publishes, with or
//                                   without a display:
//                                   ioreg -rtc IOMobileFramebufferShim -d1 -w0 | grep -E '\+-o disp|ProductAttributes'
//   kosmos-probe secure-input       Which Carbon hotkeys fire while Secure Input is on, from
//                                   real key presses its window asks for (SecureInput.swift).
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
case "displays": displays()
case "secure-input": secureInput()
default:
    print("usage: kosmos-probe barrier [cycles] | survive-kill | bar | destroyed-space | gone-space-recovery | displays | secure-input")
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
