// An empirical sweep of the private SkyLight window calls, to show which can change another
// app's window from an ordinary process like Kosmos (blip-research.md decided this from the
// disassembly; the sweep confirms it by experiment).
//
//   kosmos-probe api-sweep [--list] [--check] [--out <path>] [--from <i>] [--to <i>]
//                                   A child of the probe, an accessory app never activated and
//                                   not managed by Kosmos, owns one 200 by 150 test window at
//                                   the bottom left of the built-in display. For each call in
//                                   the table (CKosmosSweep), the probe reads the window back,
//                                   makes the call from a short-lived grandchild so a
//                                   client-side crash or hang (5 s) cannot stop the sweep,
//                                   reads the window again at once and after 100 ms, puts the
//                                   window back, and appends a JSONL record. The calls run
//                                   read-only and least risky first, with updates, levels and
//                                   shapes last.
//                                     --list   prints every call with its signature source and
//                                              arguments and calls nothing
//                                     --check  runs only the 3 read-only calls, to check the
//                                              harness: SLSGetWindowBounds, SLSGetWindowAlpha,
//                                              SLSGetWindowLevel
//                                     --out    the JSONL path (default under
//                                              ~/.cache/kosmos-handoff)
//                                     --from, --to  the inclusive range of table indices to run
//                                   The grandchild uses its own SkyLight connection, foreign to
//                                   the test window, as Kosmos's is. A live call could in
//                                   principle crash WindowServer, so run --list and --check
//                                   first. Needs no permission.
import AppKit
import CKosmosSweep
import Darwin
import Foundation
import KosmosSkyLight

// MARK: - The parent: orchestration

@MainActor func apiSweep(_ arguments: [String]) {
    let list = arguments.contains("--list")
    let check = arguments.contains("--check")
    let out = flagValue(arguments, "--out")
    let from = flagValue(arguments, "--from").flatMap(Int.init)
    let to = flagValue(arguments, "--to").flatMap(Int.init)

    if list {
        printList()
        return
    }

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    // The window-owner child. It prints "id x y w h" and, on "reset", puts the window back and
    // prints its state.
    let child = Child(["api-sweep-window"])
    let opened = child.line().split(whereSeparator: \.isWhitespace).compactMap { Double($0) }
    guard opened.count == 5, let window = UInt32(exactly: opened[0]) else {
        print("error: the test window did not open")
        child.terminate()
        exit(1)
    }
    let rest = CGRect(x: opened[1], y: opened[2], width: opened[3], height: opened[4])
    print(String(format: "test window %d, 200 by 150 at (%.0f, %.0f) on the built-in display, pid %d",
                 window, rest.minX, rest.minY, child.pid))

    switch kosmosListsWindow(window) {
    case .present:
        print("error: Kosmos manages the test window (\(window)); aborting so the sweep does not fight it")
        child.terminate()
        exit(1)
    case .absent:
        print("Kosmos is running and does not manage the test window")
    case .unavailable:
        print("Kosmos is not running, so it cannot manage the test window")
    }

    let path = out ?? defaultOutPath(check: check)
    guard let file = openOutFile(path) else {
        print("error: cannot open \(path)")
        child.terminate()
        exit(1)
    }
    print("writing \(path)")

    let indices = check ? checkIndices() : callIndices(from: from, to: to)
    print("\(indices.count) call\(indices.count == 1 ? "" : "s") to run\n")

    for (position, index) in indices.enumerated() {
        let entry = SweepRow(index)
        resetWindow(child, rest: rest) // start from rest
        let before = readState(window)
        let started = Date()
        let call = runCall(index: index, window: window)
        let after = readState(window)
        pumpEvents(0.1)
        let persist = readState(window)
        let ms = Date().timeIntervalSince(started) * 1000
        let reset = resetWindow(child, rest: rest)

        let changed = diff(before, after)
        let persisted = diff(before, persist)
        let record = recordJSON(index: index, entry: entry, call: call, before: before, after: after,
                                persist: persist, changed: changed, persisted: persisted, reset: reset, ms: ms)
        append(file, record)
        print(String(format: "[%d/%d] %-42s %-7s rc=%@ changed=%@",
                     position + 1, indices.count, (entry.name as NSString).utf8String!, call.outcome,
                     call.rc.map(String.init) ?? "-", changed.isEmpty ? "none" : changed.joined(separator: ","))
              + (persisted.isEmpty || persisted == changed ? "" : " persisted=\(persisted.joined(separator: ","))"))
    }

    fclose(file)
    child.quit()
    print("\ndone")
    exit(0)
}

private func flagValue(_ arguments: [String], _ flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

/// The table rows the sweep calls, in order. LIST and EXCLUDE rows are skipped.
private func callIndices(from: Int?, to: Int?) -> [Int] {
    (0..<Int(kosmos_sweep_count())).filter { index in
        SweepRow(index).kind == KSWEEP_CALL && index >= (from ?? 0) && index <= (to ?? Int.max)
    }
}

/// The three read-only calls, for --check.
private func checkIndices() -> [Int] {
    let wanted = ["SLSGetWindowBounds", "SLSGetWindowAlpha", "SLSGetWindowLevel"]
    return (0..<Int(kosmos_sweep_count())).filter { wanted.contains(SweepRow($0).name) }
}

// MARK: - One call, in a short-lived grandchild

private struct CallOutcome {
    let rc: Int64?
    let outcome: String // ok, timeout, crash, spawn-failed
}

/// Runs `api-sweep-call <index> <window>` and waits up to 5 s for its "rc <n>" line. A crash
/// closes the pipe with no line; a hang hits the timeout and the process is killed.
@MainActor private func runCall(index: Int, window: UInt32) -> CallOutcome {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    process.arguments = ["api-sweep-call", String(index), String(window)]
    let output = Pipe()
    process.standardOutput = output
    process.standardInput = Pipe()
    let fd = output.fileHandleForReading.fileDescriptor
    let done = DispatchSemaphore(value: 0)
    let box = CallBox()
    Thread.detachNewThread {
        var bytes: [UInt8] = [], chunk = [UInt8](repeating: 0, count: 256)
        while true {
            let n = read(fd, &chunk, 256)
            if n <= 0 { break } // EOF: the grandchild exited, perhaps by a crash
            bytes.append(contentsOf: chunk[0..<n])
            if bytes.contains(0x0a) { break }
        }
        if let newline = bytes.firstIndex(of: 0x0a) {
            let line = String(decoding: bytes[0..<newline], as: UTF8.self)
            if line.hasPrefix("rc ") { box.set(rc: Int64(line.dropFirst(3)), outcome: "ok") }
        }
        done.signal()
    }
    do {
        try process.run()
    } catch {
        return CallOutcome(rc: nil, outcome: "spawn-failed")
    }
    if done.wait(timeout: .now() + 5) == .timedOut {
        process.terminate()
        process.waitUntilExit()
        return CallOutcome(rc: nil, outcome: "timeout")
    }
    process.waitUntilExit()
    let (rc, outcome) = box.get()
    return CallOutcome(rc: rc, outcome: outcome)
}

private final class CallBox: @unchecked Sendable {
    private let lock = NSLock()
    private var rc: Int64?
    private var outcome = "crash"
    func set(rc: Int64?, outcome: String) { lock.lock(); self.rc = rc; self.outcome = outcome; lock.unlock() }
    func get() -> (Int64?, String) { lock.lock(); defer { lock.unlock() }; return (rc, outcome) }
}

// MARK: - Reading the window back

private struct Reading {
    let state: KSweepState
    let spaces: [UInt64]
}

private func readState(_ window: UInt32) -> Reading {
    Reading(state: kosmos_sweep_read(window), spaces: SkyLight.spaces(of: window) ?? [])
}

/// The fields that differ between two readings, in the order origin, size, alpha, level,
/// ordering, transform, spaces, readability.
private func diff(_ a: Reading, _ b: Reading) -> [String] {
    var fields: [String] = []
    if abs(a.state.bounds.origin.x - b.state.bounds.origin.x) > 0.5
        || abs(a.state.bounds.origin.y - b.state.bounds.origin.y) > 0.5 { fields.append("origin") }
    if abs(a.state.bounds.width - b.state.bounds.width) > 0.5
        || abs(a.state.bounds.height - b.state.bounds.height) > 0.5 { fields.append("size") }
    if abs(a.state.alpha - b.state.alpha) > 0.01 { fields.append("alpha") }
    if a.state.level != b.state.level { fields.append("level") }
    if a.state.orderedIn != b.state.orderedIn { fields.append("orderedIn") }
    if !transformsEqual(a.state.transform, b.state.transform) { fields.append("transform") }
    if Set(a.spaces) != Set(b.spaces) { fields.append("spaces") }
    if (a.state.ok != 0) != (b.state.ok != 0) { fields.append("readable") }
    return fields
}

private func transformsEqual(_ a: CGAffineTransform, _ b: CGAffineTransform) -> Bool {
    let eps = 0.001
    return abs(a.a - b.a) < eps && abs(a.b - b.b) < eps && abs(a.c - b.c) < eps
        && abs(a.d - b.d) < eps && abs(a.tx - b.tx) < eps && abs(a.ty - b.ty) < eps
}

// MARK: - The reset between calls

private struct ResetResult {
    let ok: Bool
    let line: String
}

/// Asks the owner child to put the window back and reads its confirmation.
@MainActor @discardableResult private func resetWindow(_ child: Child, rest: CGRect) -> ResetResult {
    child.send("reset")
    let line = child.line()
    let tokens = line.split(whereSeparator: \.isWhitespace)
    guard tokens.first == "reset", tokens.count >= 5, let x = Double(tokens[1]), let y = Double(tokens[2]),
          let w = Double(tokens[3]), let h = Double(tokens[4]) else {
        return ResetResult(ok: false, line: line)
    }
    let ok = abs(x - rest.minX) < 2 && abs(y - rest.minY) < 2 && abs(w - rest.width) < 2 && abs(h - rest.height) < 2
    return ResetResult(ok: ok, line: line)
}

// MARK: - The list and the JSONL

private struct SweepRow {
    let name: String, category: String, signature: String, source: String, args: String, note: String
    let status: KSweepSignature, kind: KSweepKind, risk: Int

    init(_ index: Int) {
        let entry = kosmos_sweep_entry(Int32(index))!.pointee
        name = String(cString: entry.name)
        category = String(cString: entry.category)
        signature = String(cString: entry.signature)
        source = String(cString: entry.source)
        args = String(cString: entry.args)
        note = String(cString: entry.note)
        status = KSweepSignature(rawValue: UInt32(entry.status))
        kind = KSweepKind(rawValue: UInt32(entry.kind))
        risk = Int(entry.risk)
    }

    var statusText: String { ["known", "inferred", "unknown"][Int(status.rawValue)] }
    var kindText: String { ["call", "list", "exclude"][Int(kind.rawValue)] }
}

private func printList() {
    let count = Int(kosmos_sweep_count())
    var call = 0, list = 0, exclude = 0, known = 0, inferred = 0, unknown = 0
    for index in 0..<count {
        let row = SweepRow(index)
        switch row.kind {
        case KSWEEP_CALL: call += 1
        case KSWEEP_LIST: list += 1
        default: exclude += 1
        }
        switch row.status {
        case KSWEEP_KNOWN: known += 1
        case KSWEEP_INFERRED: inferred += 1
        default: unknown += 1
        }
    }
    print("\(count) entries: \(call) called, \(list) listed only, \(exclude) excluded as too risky")
    print("signatures: \(known) known, \(inferred) inferred, \(unknown) unknown\n")
    for index in 0..<count {
        let row = SweepRow(index)
        print("[\(index)] \(row.name)  (\(row.category), risk \(row.risk), \(row.kindText), \(row.statusText))")
        print("     sig:    \(row.signature)")
        print("     source: \(row.source)")
        if row.args != "-" && !row.args.isEmpty { print("     args:   \(row.args)") }
        if !row.note.isEmpty { print("     note:   \(row.note)") }
    }
}

private func recordJSON(index: Int, entry: SweepRow, call: CallOutcome, before: Reading, after: Reading,
                        persist: Reading, changed: [String], persisted: [String], reset: ResetResult, ms: Double) -> Data {
    let record: [String: Any] = [
        "i": index,
        "name": entry.name,
        "category": entry.category,
        "sig": entry.statusText,
        "source": entry.source,
        "args": entry.args,
        "risk": entry.risk,
        "rc": call.rc.map { Int($0) } ?? NSNull(),
        "outcome": call.outcome,
        "changed": !changed.isEmpty,
        "changedFields": changed,
        "persisted": !persisted.isEmpty,
        "persistedFields": persisted,
        "before": stateJSON(before),
        "after": stateJSON(after),
        "persist": stateJSON(persist),
        "reset_ok": reset.ok,
        "ms": (ms * 100).rounded() / 100,
    ]
    let data = (try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])) ?? Data("{}".utf8)
    return data
}

private func stateJSON(_ reading: Reading) -> [String: Any] {
    let s = reading.state
    let t = s.transform
    func round1(_ v: CGFloat) -> Double { (Double(v) * 10).rounded() / 10 }
    return [
        "ok": s.ok != 0,
        "x": round1(s.bounds.origin.x),
        "y": round1(s.bounds.origin.y),
        "w": round1(s.bounds.width),
        "h": round1(s.bounds.height),
        "alpha": (Double(s.alpha) * 1000).rounded() / 1000,
        "level": Int(s.level),
        "orderedIn": s.orderedIn != 0,
        "transform": [t.a, t.b, t.c, t.d, t.tx, t.ty].map { (Double($0) * 1000).rounded() / 1000 },
        "spaces": reading.spaces.map(String.init),
    ]
}

private func openOutFile(_ path: String) -> UnsafeMutablePointer<FILE>? {
    try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                             withIntermediateDirectories: true)
    return fopen(path, "w")
}

private func append(_ file: UnsafeMutablePointer<FILE>, _ line: Data) {
    var bytes = [UInt8](line)
    bytes.append(0x0a)
    fwrite(bytes, 1, bytes.count, file)
    fflush(file) // a WindowServer crash then leaves the record up to the crash
}

private func defaultOutPath(check: Bool) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
    return "\(home)/.cache/kosmos-handoff/api-sweep-\(check ? "check-" : "")\(stamp).jsonl"
}

private enum KosmosListing { case present, absent, unavailable }

/// Whether `kosmos list-windows` shows the test window. The CLI reaches the running app's
/// socket; when Kosmos is not running the command fails.
private func kosmosListsWindow(_ window: UInt32) -> KosmosListing {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", "kosmos list-windows"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    guard (try? process.run()) != nil else { return .unavailable }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return .unavailable }
    let ids = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
        .compactMap { $0.split(whereSeparator: \.isWhitespace).first.flatMap { UInt32($0) } }
    return ids.contains(window) ? .present : .absent
}

// MARK: - The window-owner child and the per-call grandchild

/// A 200 by 150 window at the bottom left of the built-in display, in an accessory app never
/// activated. Prints "id x y w h", and on "reset" puts the window back and prints its state.
@MainActor func apiSweepWindow() -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let screen = builtInScreen()
    let display = CGDisplayBounds(screen.displayID)
    let rest = CGRect(x: display.minX + 20, y: display.maxY - 150 - 40, width: 200, height: 150)
    let window = NSWindow(contentRect: .zero, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.title = "kosmos-probe api-sweep"
    window.backgroundColor = NSColor(srgbRed: 0.2, green: 0.5, blue: 1, alpha: 1)
    window.animationBehavior = .none
    window.isReleasedWhenClosed = false
    window.setFrame(appKitRect(rest), display: true)
    window.orderFrontRegardless()
    let id = UInt32(window.windowNumber)
    print("\(id) \(Int(rest.minX)) \(Int(rest.minY)) \(Int(rest.width)) \(Int(rest.height))")

    Thread.detachNewThread {
        while let line = readLine() {
            guard line == "reset" else { continue }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    kosmos_sweep_reset(id, rest)
                    window.setFrame(appKitRect(rest), display: true)
                    window.alphaValue = 1
                    window.level = .normal
                    window.orderFrontRegardless()
                    let s = kosmos_sweep_read(id)
                    print("reset \(Int(s.bounds.origin.x)) \(Int(s.bounds.origin.y)) \(Int(s.bounds.width)) \(Int(s.bounds.height))"
                          + " a=\(s.alpha) lvl=\(s.level) in=\(s.orderedIn != 0)")
                }
            }
        }
        exit(0)
    }
    app.run()
    exit(0)
}

/// Makes one call from a fresh SkyLight connection, foreign to the test window, as Kosmos's
/// is, then prints its return code and exits. Isolated so a crash or hang cannot stop the
/// sweep.
func apiSweepCall(index: Int, window: UInt32) -> Never {
    let rc = kosmos_sweep_perform(Int32(index), window)
    print("rc \(rc)")
    exit(0)
}
