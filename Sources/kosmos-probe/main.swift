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
