// The holding Space and recovery (docs/hiding.md).
//
//   kosmos-probe barrier [cycles]   Whether one bridged read returns only after earlier
//                                   conceals and reveals have landed.
//   kosmos-probe destroyed-space    What a destroyed Space's members read as.
//   kosmos-probe survive-kill       Conceals a panel with the guardian armed, then kills
//                                   itself. Check that the panel is back, the Space gone and
//                                   the record clear. Quit Kosmos first.
//   kosmos-probe reveal             Where an exclusive add and a removal put a window. Its app
//                                   can never be front, so it runs beside a live session.
//   kosmos-probe holding            Who owns each window in a running Kosmos's holding Spaces.
//                                   Read only.
import AppKit
import CKosmos
import KosmosRecovery
import KosmosSkyLight

/// Another app's window for the probe to act on, as Kosmos does. Prints its id and stays
/// until killed.
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

/// Invisible and off every display, in an app that can never be front. Prints its id. With
/// `levels` it prints the uptime and level of each change (`kosmos-probe level`).
@MainActor func showHiddenWindow(levels: Bool) -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let origin = CommandLine.arguments.contains("onscreen") ? NSScreen.main?.visibleFrame.origin ?? .zero : NSPoint(x: -4000, y: -4000)
    let window = NSWindow(contentRect: NSRect(origin: origin, size: NSSize(width: 60, height: 60)),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.alphaValue = CommandLine.arguments.contains("opaque") ? 1 : 0
    window.ignoresMouseEvents = true
    window.orderFrontRegardless()
    print(window.windowNumber)
    if levels {
        for (step, level) in [NSWindow.Level.floating, .normal, .floating, .normal, .floating, .normal].enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(step + 1)) {
                let before = uptime()
                window.level = level
                print(String(format: "%.3f level %d", before, level.rawValue))
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 7.5) { exit(0) }
    }
    app.run()
    exit(0)
}

func spawnPanel(_ command: String = "panel") -> (Child, UInt32) {
    let child = Child([command])
    let window = child.readWindows()[0]
    Thread.sleep(forTimeInterval: 0.3)   // let the panel reach the screen
    return (child, window)
}

func barrier(cycles: Int) {
    let (panel, window) = spawnPanel()
    let start = ContinuousClock.now
    let space = kosmos_holding_create()
    guard space != 0 else { print("holding Space not created"); panel.terminate(); exit(1) }
    print("holding Space \(space) created in \(String(format: "%.2f", elapsed(start))) ms, panel window \(window)")
    defer {
        var ids = [window]
        kosmos_remove_windows(space, &ids, 1)
        kosmos_space_destroy(space)
        panel.terminate()
    }

    var ids = [window]
    for useBarrier in [false, true] {
        var concealed = 0, revealed = 0
        var opTimes: [Double] = [], barrierTimes: [Double] = []
        for _ in 0..<cycles {
            var t = ContinuousClock.now
            kosmos_add_windows(space, &ids, 1, false)
            opTimes.append(elapsed(t))
            if useBarrier { t = .now; _ = kosmos_barrier(space); barrierTimes.append(elapsed(t)) }
            if inSpace(window, space) { concealed += 1 }
            Thread.sleep(forTimeInterval: 0.02)

            t = .now
            kosmos_remove_windows(space, &ids, 1)
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
    print("panel pid \(panel.pid) window \(window)")
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
    let original = SkyLight.spaces(of: window)?.first ?? 0
    record.windows = [.init(id: window, owner: ProcessIdentity.of(panel.pid)!, originalSpace: original)]
    file.publish(record)

    var ids = [window]
    kosmos_add_windows(space, &ids, 1, false)
    _ = kosmos_barrier(space)
    print("panel concealed in Space \(space): \(inSpace(window, space)); killing myself")
    withExtendedLifetime(lock) {}
    kill(getpid(), SIGKILL)
    exit(1)
}

@MainActor func destroyedSpace() {
    _ = NSApplication.shared   // bridged operations need an AppKit client
    let space = kosmos_holding_create()
    guard space != 0 else { print("holding Space not created"); return }
    let before = SkyLight.windows(in: space)
    print("live Space \(space): members \(before.map { "\($0)" } ?? "nil (read failed)")")
    kosmos_space_destroy(space)
    _ = kosmos_barrier(space)
    for delay in [0.0, 0.1, 1.0] {
        Thread.sleep(forTimeInterval: delay)
        let after = SkyLight.windows(in: space)
        print("after destroy (+\(delay) s): members \(after.map { "\($0)" } ?? "nil (read failed)"), barrier \(kosmos_barrier(space))")
    }
    let never: UInt64 = 0x7fff_ffff_0000
    print("a Space id that never existed: members \(SkyLight.windows(in: never).map { "\($0)" } ?? "nil (read failed)")")
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
        kosmos_remove_windows(space, &ids, 1)
        kosmos_space_destroy(space)
    }
    print("window \(window), ordinary Space \(desktop), holding Space \(space)")
    func state(_ step: String) -> (ordinary: [UInt64], held: Bool) {
        _ = kosmos_barrier(space)
        let ordinary = SkyLight.spaces(of: window) ?? [], held = inSpace(window, space)
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

@MainActor func holding() {
    guard let record = RecordFile.peek(KosmosFiles.record) else { return print("no recovery record") }
    let recorded = Set(record.windows.map(\.id)), apps = Set(record.windows.map(\.owner))
    print("record: Spaces \(record.spaces), \(record.windows.count) windows of pids \(Set(apps.map(\.pid)).sorted())")
    for space in record.spaces {
        guard let members = SkyLight.windows(in: space) else {
            print("Space \(space): no list, so gone or unread")
            continue
        }
        print("Space \(space): \(members.count) members")
        let rows = Dictionary(SkyLight.rows(members).map { ($0.id, $0) }) { first, _ in first }
        for id in members.sorted() {
            guard let row = rows[id] else {
                print("  \(id): no row, recorded \(recorded.contains(id))")
                continue
            }
            // A command line tool, as borders, has no NSRunningApplication.
            var name = [CChar](repeating: 0, count: 256)
            let app = NSRunningApplication(processIdentifier: row.pid)?.localizedName
                ?? (proc_name(row.pid, &name, UInt32(name.count)) > 0 ? name.withUnsafeBufferPointer { String(cString: $0.baseAddress!) } : "?")
            let spaces = SkyLight.spaces(of: id).map { "\($0)" } ?? "unread"
            let ownsRecorded = ProcessIdentity.of(row.pid).map { apps.contains($0) }.map { "\($0)" } ?? "unread"
            print("  \(id): pid \(row.pid) \(app), parent \(row.parent), level \(row.level), Spaces \(spaces), "
                  + "recorded \(recorded.contains(id)), owner owns a recorded window \(ownsRecorded)")
        }
    }
}
