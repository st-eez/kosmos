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
//   kosmos-probe raise <stub.app> <stub.app> <stub.app>
//                                   Does keying a window through the focus path also raise
//                                   it above overlapping windows, and does AXRaise first?
//   kosmos-probe sweep <stub.app>...
//                                   CPU of the app usage daemons while focus sweeps across
//                                   windows of different apps. script/sweep.sh builds the
//                                   stub apps and runs it.
import AppKit
import CKosmos
import KosmosRecovery
import KosmosSkyLight
import Synchronization

setvbuf(stdout, nil, _IOLBF, 0)
let arguments = CommandLine.arguments.dropFirst()

switch arguments.first {
case "panel": showPanel()
case "barrier": barrier(cycles: arguments.dropFirst().first.flatMap(Int.init) ?? 50)
case "survive-kill": surviveKill()
case "bar": bar()
case "destroyed-space": destroyedSpace()
case "gone-space-recovery": goneSpaceRecovery()
case "stub": showStub(index: arguments.dropFirst().first.flatMap(Int.init) ?? 0,
                      windows: arguments.dropFirst(2).first.flatMap(Int.init) ?? 1,
                      accessory: arguments.contains("accessory"), spread: arguments.contains("spread"))
case "raise" where arguments.count == 4: raise(Array(arguments.dropFirst()))
case "sweep" where arguments.count >= 3: sweep(Array(arguments.dropFirst()))
default:
    print("""
        usage: kosmos-probe barrier [cycles] | survive-kill | bar | destroyed-space | gone-space-recovery
               | raise <stub.app> <stub.app> <stub.app> | sweep <stub.app>...
        """)
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

// MARK: Focus follows mouse

/// A small app for the focus probes, run from its own bundle so that macOS counts each stub
/// as a separate app. A running window manager leaves its windows alone: a regular stub's
/// windows sit above level 0, and an accessory app's windows are never managed. Prints its
/// window ids, and exits when its standard input closes, so it never outlives the probe
/// that started it.
@MainActor func showStub(index: Int, windows: Int, accessory: Bool, spread: Bool) -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(accessory ? .accessory : .regular)
    let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    var ids: [Int] = []
    for offset in 0..<windows {
        // Stacked with an offset, or side by side.
        let frame = NSRect(x: screen.maxX - CGFloat(index + 1) * 180 + CGFloat(offset) * (spread ? -180 : 40),
                           y: screen.minY + 20 + CGFloat(spread ? 0 : offset) * 30, width: 170, height: 90)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "kosmos-probe \(index)"
        if !accessory { window.level = .floating }
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        ids.append(window.windowNumber)
    }
    print(ids.map(String.init).joined(separator: " "))
    // The focus path's key record arrives as a left mouse down.
    if accessory {
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { event in
            let line = "stub \(index): mouse down for window \(event.windowNumber) at \(event.locationInWindow), "
                + "key window before it: \(NSApp.keyWindow?.windowNumber ?? 0)\n"
            FileHandle.standardError.write(Data(line.utf8))
            return event
        }
    }
    Thread.detachNewThread {
        while !FileHandle.standardInput.availableData.isEmpty {}
        exit(0)
    }
    app.run()
    exit(0)
}

struct Stub {
    let process: Process
    /// Held open for the stub's lifetime: the stub exits when it closes, which also happens
    /// when the probe dies.
    let input: Pipe
    let windows: [UInt32]
    var pid: pid_t { process.processIdentifier }
}

/// Runs the stub bundle's executable directly, never through `open`.
func launchStub(_ bundle: String, index: Int, windows: Int = 1, accessory: Bool = false, spread: Bool = false) -> Stub {
    guard let executable = Bundle(path: bundle)?.executableURL else {
        print("no executable in \(bundle)")
        exit(1)
    }
    let process = Process()
    process.executableURL = executable
    process.arguments = ["stub", String(index), String(windows)] + (accessory ? ["accessory"] : []) + (spread ? ["spread"] : [])
    let input = Pipe(), output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    try! process.run()
    var line = Data()
    while !line.contains(UInt8(ascii: "\n")) {
        let chunk = output.fileHandleForReading.availableData
        guard !chunk.isEmpty else { print("stub \(bundle) exited"); exit(1) }
        line.append(chunk)
    }
    let ids = String(decoding: line, as: UTF8.self).split(whereSeparator: \.isWhitespace).compactMap { UInt32($0) }
    return Stub(process: process, input: input, windows: ids)
}

/// Waits with the main run loop turning, so NSWorkspace sees activations.
@MainActor func wait(_ seconds: Double) {
    RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds))
}

@MainActor func frontPID() -> pid_t? { NSWorkspace.shared.frontmostApplication?.processIdentifier }

/// Keys level 0 windows through the focus path, alone or after AXRaise, and prints the
/// stacking order and each app's focused window. A1 and A2 overlap, B1 covers A1, and C1
/// and C2 sit side by side. The stubs are accessory apps, which a running Kosmos leaves
/// alone.
@MainActor func raise(_ bundles: [String]) {
    _ = NSApplication.shared
    let a = launchStub(bundles[0], index: 0, windows: 2, accessory: true)
    let b = launchStub(bundles[1], index: 0, accessory: true)
    let c = launchStub(bundles[2], index: 2, windows: 2, accessory: true, spread: true)
    defer { for stub in [a, b, c] { stub.process.terminate() } }
    let names = [a.windows[0]: "A1", a.windows[1]: "A2", b.windows[0]: "B1", c.windows[0]: "C1", c.windows[1]: "C2"]
    func order() -> String {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let ids = list.compactMap { ($0[kCGWindowNumber as String] as? Int).map(UInt32.init) }
        return ids.compactMap { names[$0] }.filter { !$0.hasPrefix("C") }.joined(separator: " over ")
    }
    func element(_ stub: Stub, _ window: UInt32) -> AXUIElement? {
        var windows: CFTypeRef?
        AXUIElementCopyAttributeValue(AXUIElementCreateApplication(stub.pid), kAXWindowsAttribute as CFString, &windows)
        return (windows as? [AXUIElement])?.first { element in
            var id: UInt32 = 0
            return _AXUIElementGetWindow(element, &id) == .success && id == window
        }
    }
    wait(0.5)
    print("start: \(order())")
    let steps: [(Stub, UInt32, Bool)] = [
        (a, a.windows[0], false), (b, b.windows[0], false), (a, a.windows[1], false), (a, a.windows[0], false),
        (c, c.windows[0], false), (c, c.windows[1], false), (c, c.windows[0], false),
        (b, b.windows[0], false), (a, a.windows[0], true), (a, a.windows[1], true), (b, b.windows[0], false),
        (a, a.windows[0], true),
    ]
    for (stub, window, raising) in steps {
        let raised = raising ? element(stub, window).map { AXUIElementPerformAction($0, kAXRaiseAction as CFString) == .success } : nil
        let keyed = kosmos_make_key(stub.pid, window)
        wait(0.3)
        var focused: CFTypeRef?
        var key: UInt32 = 0
        if AXUIElementCopyAttributeValue(AXUIElementCreateApplication(stub.pid), kAXFocusedWindowAttribute as CFString,
                                         &focused) == .success, let focused {
            _ = _AXUIElementGetWindow((focused as! AXUIElement), &key)
        }
        let how = raised.map { $0 ? "AXRaise, then keyed" : "AXRaise failed, keyed" } ?? "keyed"
        print("\(how) \(names[window]!) (\(keyed ? "ok" : "failed")): \(order()); its app is front: "
              + "\(frontPID() == stub.pid), its focused window: \(names[key] ?? String(key))")
    }
}

/// The focus queue as Kosmos runs it (FocusQueue.swift): serial and off the main thread,
/// and a request is dropped when a newer one exists by the time the queue reaches it.
final class ProbeFocusQueue: Sendable {
    struct Counts {
        var performed = 0, dropped = 0, failed = 0
        var times: [Double] = []
    }

    private let queue = DispatchQueue(label: "kosmos-probe.focus", qos: .userInteractive)
    private let current = Atomic<UInt64>(0)
    let counts = Mutex(Counts())

    func request(_ stub: Stub, _ window: UInt32) {
        let generation = current.add(1, ordering: .relaxed).newValue
        let pid = stub.pid
        queue.async { [self] in
            guard current.load(ordering: .relaxed) == generation else { return counts.withLock { $0.dropped += 1 } }
            let start = ContinuousClock.now
            let keyed = kosmos_make_key(pid, window)
            let time = elapsed(start)
            counts.withLock {
                if keyed { $0.performed += 1 } else { $0.failed += 1 }
                $0.times.append(time)
            }
        }
    }

    func drain() { queue.sync {} }
}

/// Seconds of CPU time per process, from `ps`, which reads other users' processes too.
func cpuTimes() -> [pid_t: (name: String, seconds: Double)] {
    let ps = Process()
    ps.executableURL = URL(fileURLWithPath: "/bin/ps")
    ps.arguments = ["-A", "-o", "pid=,time=,comm="]
    let output = Pipe()
    ps.standardOutput = output
    try! ps.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    ps.waitUntilExit()
    var times: [pid_t: (name: String, seconds: Double)] = [:]
    for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
        let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard fields.count == 3, let pid = pid_t(fields[0]) else { continue }
        // [hours:]minutes:seconds.hundredths
        let seconds = fields[1].split(separator: ":").reduce(0.0) { $0 * 60 + (Double($1) ?? 0) }
        times[pid] = (String(fields[2].split(separator: "/").last ?? ""), seconds)
    }
    return times
}

func processCPU() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
}

/// Focus sweeps across one window of each stub app, as the pointer does crossing windows
/// of different apps, measured against idle phases (DESIGN.md, sections 2 and 5.11). A
/// sweep crosses every window, 40 ms per window, then rests on the last one; sweeps run
/// back and forth, two a second. With no dwell every window crossed is keyed. With a dwell
/// longer than the crossing time only the window the pointer rests on is. Each phase
/// lasts 12 s, and its CPU is read 6 s after its last activation, so daemons that queue
/// work are counted. The phase order rotates each round.
@MainActor func sweep(_ bundles: [String], rounds: Int = 4) {
    _ = NSApplication.shared
    let stubs = bundles.enumerated().map { launchStub($1, index: $0) }
    defer { for stub in stubs { stub.process.terminate() } }
    let crossing = 0.040, period = 0.5, length = 12.0, tail = 6.0, dwell = 0.1
    let watched = ["BiomeAgent", "biomed", "duetexpertd", "ContextStoreAgent", "coreduetd", "WindowManager",
                   "spotlightknowledged", "spotlightknowledged.importer", "spotlightknowledged.updater",
                   "knowledge-agent", "siriknowledged", "MenuBarAgent", "WindowServer", "Dock", "Kosmos"]
    let stubPIDs = Set(stubs.map(\.pid))
    let focus = ProbeFocusQueue()
    focus.request(stubs[0], stubs[0].windows[0])
    wait(1)

    enum Phase: String, CaseIterable { case idle, noDwell = "no dwell", dwell }
    struct Totals {
        var seconds = 0.0, sweeps = 0, requests = 0, frontMatched = 0, probeCPU = 0.0
        var cpu: [String: Double] = [:]
    }
    var totals: [Phase: Totals] = [:]
    var at = 0   // index of the stub the pointer rests on
    for round in 0..<rounds {
        let phases = Phase.allCases.indices.map { Phase.allCases[($0 + round) % Phase.allCases.count] }
        for phase in phases {
            let before = cpuTimes(), probeBefore = processCPU(), start = ContinuousClock.now
            var total = totals[phase] ?? Totals()
            if phase == .idle {
                wait(length)
            } else {
                while elapsed(start) < length * 1000 {
                    let sweepStart = ContinuousClock.now
                    let order = at == 0 ? Array(stubs.indices) : Array(stubs.indices.reversed())
                    for index in order.dropFirst() {
                        if phase == .noDwell || index == order.last! {
                            if phase == .dwell { wait(dwell) }
                            focus.request(stubs[index], stubs[index].windows[0])
                            total.requests += 1
                        }
                        if index != order.last! { wait(crossing) }
                    }
                    at = order.last!
                    wait(period - elapsed(sweepStart) / 1000)
                    total.sweeps += 1
                    if frontPID() == stubs[at].pid { total.frontMatched += 1 }
                }
            }
            focus.drain()
            wait(tail)
            let after = cpuTimes()
            total.seconds += elapsed(start) / 1000
            total.probeCPU += processCPU() - probeBefore
            for (pid, entry) in after {
                guard let old = before[pid], old.name == entry.name else { continue }
                let name = stubPIDs.contains(pid) ? "stubs" : entry.name
                total.cpu[name, default: 0] += entry.seconds - old.seconds
            }
            totals[phase] = total
            print("round \(round + 1) \(phase.rawValue): \(String(format: "%.1f", elapsed(start) / 1000)) s")
        }
    }

    let counts = focus.counts.withLock { $0 }
    print(String(format: "focus calls: %d performed, %d dropped, %d failed; median %.2f ms, p95 %.2f ms",
                 counts.performed, counts.dropped, counts.failed,
                 percentile(counts.times, 0.5), percentile(counts.times, 0.95)))
    for phase in Phase.allCases {
        let total = totals[phase]!
        print(String(format: "%@: %.0f s, %d sweeps, %d activations, front app right after %d sweeps, probe %.0f ms CPU",
                     phase.rawValue, total.seconds, total.sweeps, total.requests, total.frontMatched, total.probeCPU * 1000))
    }
    // The two sweep phases differ only in how many windows they key, so their difference
    // is the cost of the extra activations; background work cancels out on average.
    let idle = totals[.idle]!, none = totals[.noDwell]!, some = totals[.dwell]!
    let extra = Double(none.requests - some.requests)
    print("CPU ms per process: idle, dwell, no dwell, and per extra activation (no dwell less dwell)")
    let shown = watched + ["stubs"] + none.cpu.keys.filter { !watched.contains($0) && $0 != "stubs" }
        .sorted { (none.cpu[$0]! - (some.cpu[$0] ?? 0)) > (none.cpu[$1]! - (some.cpu[$1] ?? 0)) }.prefix(6)
    for name in shown {
        let values = [idle, some, none].map { ($0.cpu[name] ?? 0) * 1000 }
        guard values.contains(where: { $0 > 0 }) else { continue }
        print(String(format: "  %@: %.0f, %.0f, %.0f, %.1f", name, values[0], values[1], values[2], (values[2] - values[1]) / extra))
    }
}
