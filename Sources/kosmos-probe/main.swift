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
//   kosmos-probe departures         When the key window leaves, which does macOS report
//                                   first: the window leaving (ordered out or destroyed) or
//                                   the next key window? Minimizes, closes and hides a
//                                   window of its own accessory app, with one clock, and
//                                   minimizes the app's last window, after which macOS may
//                                   report no key window at all.
//                                   The window belongs to an accessory app, which Kosmos
//                                   does not manage.
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
case "hidden-window": showHiddenWindow()
case "reveal": reveal()
case "displays": displays()
case "secure-input": secureInput()
default:
    print("usage: kosmos-probe barrier [cycles] | survive-kill | bar | destroyed-space | gone-space-recovery | fullscreen | departures | reveal | displays | secure-input")
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

nonisolated(unsafe) var fullscreenStart = ContinuousClock.now
nonisolated(unsafe) var probeWindow: UInt32 = 0

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
    fullscreenStart = .now
    print("window \(probeWindow), pid \(child.processIdentifier)")
    pipe.fileHandleForReading.readabilityHandler = { handle in
        let text = String(decoding: handle.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { print(String(format: "%7.1f ms child: ", elapsed(fullscreenStart)) + text) }
    }
    for id: UInt32 in [1325, 1326, 1327, 1328, 1401, 806, 807, 808, 815, 816] {
        _ = SLSRegisterConnectionNotifyProc(SLSMainConnectionID(), { id, data, length, _, _ in
            let bytes = UnsafeRawBufferPointer(start: data, count: data == nil ? 0 : length)
            func u32(_ offset: Int) -> UInt32 { bytes.count >= offset + 4 ? bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self) : 0 }
            func u64(_ offset: Int) -> UInt64 { bytes.count >= offset + 8 ? bytes.loadUnaligned(fromByteOffset: offset, as: UInt64.self) : 0 }
            switch id {
            case 1325, 1326:
                guard u32(8) == probeWindow else { return }
                print(String(format: "%7.1f ms event %d space %llu", elapsed(fullscreenStart), id, u64(0)))
                // The check the inventory makes on these events, off the main thread.
                DispatchQueue.global(qos: .userInitiated).async {
                    let state = Displays.isFullscreen(probeWindow).map { "\($0)" } ?? "nil (no Space)"
                    print(String(format: "%7.1f ms   Displays.isFullscreen: ", elapsed(fullscreenStart)) + state)
                }
            case 1327, 1328:
                print(String(format: "%7.1f ms event %d space %llu", elapsed(fullscreenStart), id, u64(0)))
            case 1401:
                print(String(format: "%7.1f ms event 1401", elapsed(fullscreenStart)))
            default:
                guard u32(0) == probeWindow else { return }
                print(String(format: "%7.1f ms event %d", elapsed(fullscreenStart), id))
            }
        }, id, nil)
    }
    var ids = [probeWindow]
    SLSRequestNotificationsForWindows(SLSMainConnectionID(), &ids, 1)
    DispatchQueue.main.asyncAfter(deadline: .now() + 10) { exit(0) }
    app.run()
    exit(0)
}

/// Milliseconds since boot, the same in every process.
func uptime() -> Double { Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e6 }

/// Two windows of an accessory app. The first is minimized and restored, then closed.
/// The second, the app's last window, is minimized and restored: does macOS report any
/// key window then, or does the app stay front with none? Then the app hides. Each key
/// change is printed with its uptime.
@MainActor func departuresWindow() -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    func window(_ x: CGFloat, _ title: String) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: x, y: 160, width: 320, height: 220),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        return window
    }
    let other = window(140, "kosmos-probe B"), first = window(500, "kosmos-probe A")
    other.makeKeyAndOrderFront(nil)
    first.makeKeyAndOrderFront(nil)
    app.activate()
    print("\(first.windowNumber) \(other.windowNumber)")
    let center = NotificationCenter.default
    center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
        let window = note.object as? NSWindow
        MainActor.assumeIsolated { print(String(format: "%.1f child: key %d", uptime(), window?.windowNumber ?? 0)) }
    }
    let say = { (text: String) in print(String(format: "%.1f child: ", uptime()) + text) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { say("minimize A"); first.miniaturize(nil) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { say("restore A"); first.deminiaturize(nil) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { say("close A"); first.close() }
    DispatchQueue.main.asyncAfter(deadline: .now() + 5.5) { say("minimize B, the last window"); other.miniaturize(nil) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 7.0) { say("restore B"); other.deminiaturize(nil) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 8.5) { say("hide app"); app.hide(nil) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) { exit(0) }
    app.run()
    exit(0)
}

nonisolated(unsafe) var departureWindows: Set<UInt32> = []

@MainActor func departures() -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let child = Process()
    child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    child.arguments = ["departures-window"]
    let pipe = Pipe()
    child.standardOutput = pipe
    try! child.run()
    var line = Data()
    while !line.contains(UInt8(ascii: "\n")) { line.append(pipe.fileHandleForReading.availableData) }
    let ids = String(decoding: line, as: UTF8.self).split(whereSeparator: \.isWhitespace).compactMap { UInt32($0) }
    departureWindows = Set(ids)
    print("windows A \(ids[0]) B \(ids[1]), pid \(child.processIdentifier)")
    pipe.fileHandleForReading.readabilityHandler = { handle in
        let text = String(decoding: handle.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { print(text) }
    }
    for id: UInt32 in [804, 806, 807, 808, 815, 816, 1325, 1326] {
        _ = SLSRegisterConnectionNotifyProc(SLSMainConnectionID(), { id, data, length, _, _ in
            let bytes = UnsafeRawBufferPointer(start: data, count: data == nil ? 0 : length)
            let window: UInt32 = id >= 1325
                ? (bytes.count >= 12 ? bytes.loadUnaligned(fromByteOffset: 8, as: UInt32.self) : 0)
                : (bytes.count >= 4 ? bytes.loadUnaligned(fromByteOffset: 0, as: UInt32.self) : 0)
            guard departureWindows.contains(window) else { return }
            print(String(format: "%.1f event %d window %d", uptime(), id, window))
        }, id, nil)
    }
    var watched = ids
    SLSRequestNotificationsForWindows(SLSMainConnectionID(), &watched, Int32(watched.count))
    let center = NSWorkspace.shared.notificationCenter
    for name in [NSWorkspace.didHideApplicationNotification, NSWorkspace.didActivateApplicationNotification,
                 NSWorkspace.didDeactivateApplicationNotification] {
        center.addObserver(forName: name, object: nil, queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let short = name.rawValue.replacingOccurrences(of: "NSWorkspace", with: "").replacingOccurrences(of: "ApplicationNotification", with: "")
            print(String(format: "%.1f workspace %@ %@", uptime(), short, app?.localizedName ?? "?"))
        }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 11) { exit(0) }
    app.run()
    exit(0)
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
    /// The window's ordinary Spaces and whether the holding Space has it, after one barrier,
    /// and whether WindowServer still reads it ordered in, as the inventory does.
    func state(_ step: String) -> (ordinary: [UInt64], held: Bool) {
        _ = kosmos_barrier(space)
        let ordinary = (kosmos_window_spaces(window) as? [UInt64]) ?? [], held = inSpace(window, space)
        let orderedIn = SkyLight.rows([window]).first.map { "\($0.orderedIn)" } ?? "no row"
        print("\(step): ordinary Spaces \(ordinary), in holding \(held), ordered in \(orderedIn)")
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
