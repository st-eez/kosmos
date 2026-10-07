// The holding Space and recovery (docs/hiding.md).
//
//   kosmos-probe barrier [cycles]   Whether one bridged read returns only after earlier
//                                   conceals and reveals have landed.
//   kosmos-probe destroyed-space    What a destroyed Space's members read as.
//   kosmos-probe survive-kill       Conceals a panel with the guardian armed, then kills
//                                   itself. Check, once the guardian's 5 s grace has passed,
//                                   that the panel is back, the Space gone and the record
//                                   clear. Quit Kosmos first.
//   kosmos-probe reveal             Where an exclusive add and a removal put a window. Its app
//                                   can never be front, so it runs beside a live session.
//   kosmos-probe holding            Who owns each window in a running Kosmos's holding Spaces.
//                                   Read only.
//   kosmos-probe concealed-move [onscreen]
//                                   Whether a concealed window's moves post the change event
//                                   the inventory reads its row at, and whether the row shows
//                                   the new frame. An invisible window of its own moves twice,
//                                   then twice in a holding Space. Its app can never be front,
//                                   so it runs beside a live session.
//   kosmos-probe ordered-out-add [trials]
//                                   Whether recovery's add lands for a window its app ordered
//                                   out, as at Command-W in an app that keeps its windows.
//                                   Recovery adds each recorded window alive, in no recorded
//                                   Space and on no Space to an ordinary Space, and keeps the
//                                   record while one stays on no Space (`RecoveryPlan.make`).
//                                   Each trial opens four windows in a child app that can never
//                                   be front and conceals each in a holding Space of the
//                                   probe's own. Two are taken out, then ordered out; two are
//                                   ordered out inside it, then taken out. One of each pair is
//                                   added to the current Space of the display under it
//                                   exclusively, as recovery adds, the other not. A window
//                                   still ordered in or on a Space before the add is not added,
//                                   since recovery would not add it. After the add and a barrier
//                                   the probe reads for 1 s whether the window's Spaces list
//                                   that Space, whether its row is ordered in and whether the
//                                   window list has it on screen, then AppKit's isVisible in
//                                   the child. 3 trials by default. The windows are 60 points
//                                   square at the bottom left of the main display at alpha 0
//                                   and ignore the mouse, so a run shows nothing on screen.
//                                   Ctrl-C quits the child, which takes its windows, and
//                                   destroys the Space.
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

/// Invisible and off every display, in an app that can never be front. Prints its id.
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

/// Like `hidden-window`, or in a corner of the main display with onscreen. Each line on its
/// standard input moves it 10 points right and makes it 1 point wider, and it prints the
/// uptime of the move and the new frame.
@MainActor func movingWindow(onscreen: Bool) -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let origin = onscreen ? NSScreen.main?.visibleFrame.origin ?? .zero : NSPoint(x: -4000, y: -4000)
    let window = NSWindow(contentRect: NSRect(origin: origin, size: NSSize(width: 60, height: 60)),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.alphaValue = 0
    window.ignoresMouseEvents = true
    window.orderFrontRegardless()
    print(window.windowNumber)
    Thread.detachNewThread {
        while readLine() != nil {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    var frame = window.frame
                    frame.origin.x += 10
                    frame.size.width += 1
                    let at = uptime()
                    window.setFrame(frame, display: false)
                    print(String(format: "%.3f %.0f %.0f", at, frame.minX, frame.width))
                }
            }
        }
        exit(0)
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
        let orderedIn = SkyLight.rows([window])?.first.map { "\($0.orderedIn)" } ?? "no row"
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
        let rows = Dictionary((SkyLight.rows(members) ?? []).map { ($0.id, $0) }) { first, _ in first }
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

nonisolated(unsafe) var concealedMoveLines: [(at: Double, text: String)] = []

/// Each move is asked 0.3 s after the last. A row counts for a move when its width is the
/// move's, since WindowServer's y is flipped from AppKit's.
@MainActor func concealedMove(onscreen: Bool) -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let start = uptime()
    func note(_ text: String, at: Double = uptime()) { concealedMoveLines.append((at, text)) }
    let child = Child(["moving-window"] + (onscreen ? ["onscreen"] : []))
    let window = child.readWindows()[0]
    var events = 0
    SkyLight.subscribe { event, _ in
        guard case .changed(let id) = event, id == window else { return }
        events += 1
        let row = SkyLight.rows([window])?.first.map { "x \(Int($0.frame.minX)) y \(Int($0.frame.minY)) width \(Int($0.frame.width))" }
        note("change event, row \(row ?? "none")")
    }
    SkyLight.watch([window])
    let space = kosmos_holding_create()
    guard space != 0 else { print("holding Space not created"); child.terminate(); exit(1) }
    var ids = [window]
    child.onLines { line in
        let fields = line.split(separator: " ")
        guard fields.count == 3, let at = Double(fields[0]) else { return }
        let text = "moved to AppKit x \(fields[1]) width \(fields[2])"
        DispatchQueue.main.async { concealedMoveLines.append((at, text)) }
    }
    let steps: [@MainActor () -> Void] = [
        { child.send("move") },
        { child.send("move") },
        {
            kosmos_add_windows(space, &ids, 1, false)
            note("concealed: barrier \(kosmos_barrier(space)), in the holding Space \(inSpace(window, space))")
        },
        { child.send("move") },
        { child.send("move") },
        {
            kosmos_remove_windows(space, &ids, 1)
            kosmos_space_destroy(space)
            child.quit()
            for line in concealedMoveLines.sorted(by: { $0.at < $1.at }) {
                print(String(format: "%8.1f ms ", line.at - start) + line.text)
            }
            print("window \(window): \(events) change events for 4 moves, 2 of them concealed")
            exit(0)
        },
    ]
    for (index, step) in steps.enumerated() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3 * Double(index + 1)) { MainActor.assumeIsolated { step() } }
    }
    app.run()
    exit(0)
}

/// The windows `ordered-out-window` opened, by number.
@MainActor private var orderedOutWindows: [Int: NSWindow] = [:]

/// Windows 60 points square at the bottom left of the main display at alpha 0, in an app
/// that can never be front. Each line on its standard input is `new`, which opens one and
/// prints its id; `out <id>`, which orders it out, as an app's close that keeps the window
/// does, and prints `out`; or `state <id>`, which prints AppKit's view of it.
@MainActor func orderedOutWindow() -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    Thread.detachNewThread {
        while let line = readLine() {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let fields = line.split(separator: " ")
                    let window = fields.count > 1 ? Int(fields[1]).flatMap { orderedOutWindows[$0] } : nil
                    switch fields.first {
                    case "new":
                        let origin = NSScreen.main?.visibleFrame.origin ?? .zero
                        let window = NSWindow(contentRect: NSRect(origin: origin, size: NSSize(width: 60, height: 60)),
                                              styleMask: [.borderless], backing: .buffered, defer: false)
                        window.alphaValue = 0
                        window.ignoresMouseEvents = true
                        window.isReleasedWhenClosed = false
                        window.orderFrontRegardless()
                        orderedOutWindows[window.windowNumber] = window
                        print(window.windowNumber)
                    case "out":
                        window?.orderOut(nil)
                        print("out")
                    case "state":
                        print(window.map { "isVisible \($0.isVisible), occlusion visible \($0.occlusionState.contains(.visible))" }
                              ?? "no such window")
                    default:
                        print("unknown command")
                    }
                }
            }
        }
        exit(0)
    }
    app.run()
    exit(0)
}

/// What WindowServer says of a window: its Spaces, its row and the window list.
private struct OrderedOutRead: CustomStringConvertible {
    let spaces: [UInt64]?
    /// Nil when the window has no row.
    let orderedIn: Bool?
    let frame: CGRect?
    let onScreen: Bool

    init(_ window: UInt32) {
        spaces = SkyLight.spaces(of: window)
        let row = SkyLight.rows([window])?.first
        orderedIn = row?.orderedIn
        frame = row?.frame
        let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], window) as? [[String: Any]])?.first
        onScreen = info?[kCGWindowIsOnscreen as String] as? Bool ?? false
    }

    /// Recovery adds such a window (`RecoveryPlan.make`).
    var orderedOutOnNoSpace: Bool { orderedIn == false && spaces?.isEmpty == true }

    var description: String {
        "Spaces \(spaces.map { "\($0)" } ?? "unread"), ordered in \(orderedIn.map { "\($0)" } ?? "no row"), on screen \(onScreen)"
    }
}

/// One window's add. The times are in ms from the add's submit, nil when it never held
/// within 1 s.
private struct OrderedOutAdd {
    var listed: Double?, orderedIn: Double?, onScreen: Double?
    /// As recovery reads it after its adds and its removals.
    var landed = false, onNoSpace = false
}

@MainActor private func orderedOutCase(_ child: Child, holding: UInt64, insideHolding: Bool, exclusive: Bool) -> OrderedOutAdd? {
    child.send("new")
    let window = child.readWindows()[0]
    Thread.sleep(forTimeInterval: 0.3)   // let the window reach the screen
    var ids = [window]
    print("  window \(window) opened: \(OrderedOutRead(window))")
    kosmos_add_windows(holding, &ids, 1, false)
    _ = kosmos_barrier(holding)
    print("    concealed: in the holding Space \(inSpace(window, holding)), \(OrderedOutRead(window))")
    func takeOut() {
        kosmos_remove_windows(holding, &ids, 1)
        _ = kosmos_barrier(holding)
        print("    taken out of the holding Space: in it \(inSpace(window, holding)), \(OrderedOutRead(window))")
    }
    func orderOut() {
        let start = ContinuousClock.now
        child.send("out \(window)")
        _ = child.line()
        while OrderedOutRead(window).orderedIn != false && elapsed(start) < 1000 { usleep(2000) }
        print(String(format: "    ordered out%@ (%.1f ms): ", insideHolding ? " inside the holding Space" : "", elapsed(start))
              + "in the holding Space \(inSpace(window, holding)), \(OrderedOutRead(window))")
    }
    if insideHolding {
        orderOut()
        takeOut()
    } else {
        takeOut()
        orderOut()
    }

    let before = OrderedOutRead(window)
    guard before.orderedOutOnNoSpace else {
        print("    not ordered out on no Space, so recovery would not add it; no add")
        return nil
    }
    let displays = Displays.current()
    guard let destination = before.frame.flatMap({ displays.currentSpace(at: CGPoint(x: $0.midX, y: $0.midY)) })
            ?? displays.ordinarySpace(original: nil) else {
        print("    no ordinary Space to add it to; no add")
        return nil
    }
    var result = OrderedOutAdd()
    let start = ContinuousClock.now
    kosmos_add_windows(destination, &ids, 1, exclusive)
    let submitted = elapsed(start)
    _ = kosmos_barrier(destination)
    let barrier = elapsed(start)
    let afterBarrier = OrderedOutRead(window)
    while true {
        let at = elapsed(start), read = OrderedOutRead(window)
        if result.listed == nil, read.spaces?.contains(destination) == true { result.listed = at }
        if result.orderedIn == nil, read.orderedIn == true { result.orderedIn = at }
        if result.onScreen == nil, read.onScreen { result.onScreen = at }
        if at >= 1000 { break }
        usleep(2000)
    }
    let after = OrderedOutRead(window)
    result.landed = displays.isInOrdinarySpace(window)
    result.onNoSpace = after.orderedIn != nil && (after.spaces ?? []).isEmpty
    child.send("state \(window)")
    func ms(_ value: Double?) -> String { value.map { String(format: "%.1f ms", $0) } ?? "never" }
    print(String(format: "    %@ add to %llu: submitted in %.2f ms, barrier back at %.2f ms; ", exclusive ? "exclusive" : "plain",
                 destination, submitted, barrier) + "right after it \(afterBarrier)")
    print("      within 1 s: the Space listed at \(ms(result.listed)), ordered in at \(ms(result.orderedIn)), "
          + "on screen at \(ms(result.onScreen)); after 1 s \(after); AppKit \(child.line())")
    print("      recovery would read the add as landed \(result.landed), the window as on no Space \(result.onNoSpace)")
    return result
}

@MainActor func orderedOutAdd(trials: Int) -> Never {
    _ = NSApplication.shared   // bridged operations need an AppKit client
    let cleanup = PeekCleanup()
    signal(SIGINT, SIG_IGN)
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    interrupt.setEventHandler { @Sendable in
        cleanup.runAll()
        print("interrupted; cleaned up")
        exit(130)
    }
    interrupt.resume()
    let holding = kosmos_holding_create()
    guard holding != 0 else { print("error: no holding Space"); exit(1) }
    cleanup.add { kosmos_space_destroy(holding) }
    // Added last, so it runs first: the windows leave with the child before the destroy.
    let child = Child(["ordered-out-window"])
    let box = Unchecked(value: child)
    cleanup.add { box.value.quit() }
    print("holding Space \(holding), child pid \(child.pid)")

    let cases = [(inside: false, exclusive: true), (false, false), (true, true), (true, false)]
    func name(_ inside: Bool, _ exclusive: Bool) -> String {
        (inside ? "ordered out inside the holding Space" : "ordered out after leaving it") + (exclusive ? ", exclusive add" : ", plain add")
    }
    var results: [String: [OrderedOutAdd?]] = [:]
    for trial in 1...max(1, trials) {
        for (inside, exclusive) in cases {
            print("trial \(trial), \(name(inside, exclusive)):")
            results[name(inside, exclusive), default: []].append(
                orderedOutCase(child, holding: holding, insideHolding: inside, exclusive: exclusive))
        }
    }
    cleanup.runAll()
    print("summary:")
    for (inside, exclusive) in cases {
        let all = results[name(inside, exclusive)] ?? [], added = all.compactMap { $0 }
        print("  \(name(inside, exclusive)): added \(added.count) of \(all.count); the Space listed it in "
              + "\(added.filter { $0.listed != nil }.count), landed as recovery reads it in \(added.filter(\.landed).count), "
              + "ordered in \(added.filter { $0.orderedIn != nil }.count), on screen \(added.filter { $0.onScreen != nil }.count), "
              + "left on no Space \(added.filter(\.onNoSpace).count)")
    }
    exit(0)
}
