// Whether writing a tiled window's tile back, when its app resizes it with no write of
// Kosmos's in flight and the mouse up, holds, or whether the app fights it (docs/geometry.md).
//
//   kosmos-probe snapback <app name> [seconds] [watch]
//                                   Watches the frames of the app's standard windows through
//                                   Accessibility every 15 ms, 120 s by
//                                   default, and Kosmos's `<id> written` lines from its log. A
//                                   frame change of a window within 150 ms of a write of
//                                   Kosmos's to it is Kosmos's, and its frame is the window's
//                                   tile. Any other change, with the left button up, is the
//                                   app's: 700 ms later, once the log has caught up, the probe
//                                   writes the tile back through Accessibility, at most 3 times
//                                   a window in 5 s, and logs what the app does after. Kosmos
//                                   takes the write back as a change of the app's and keeps it.
//                                   With `watch` it writes nothing and only logs the changes.
import AppKit
import KosmosCore
import KosmosSkyLight

private struct Change {
    let window: UInt32, at: Date, frame: CGRect
}

private final class KosmosWrites: @unchecked Sendable {
    private let lock = NSLock()
    private var writes: [(window: UInt32, at: Date)] = []

    func add(_ window: UInt32, _ at: Date) { lock.withLock { writes.append((window, at)) } }

    func near(_ window: UInt32, _ at: Date, within: TimeInterval) -> Bool {
        lock.withLock { writes.contains { $0.window == window && abs($0.at.timeIntervalSince(at)) <= within } }
    }
}

private func streamKosmosWrites(into writes: KosmosWrites) -> Process {
    let process = Process(), pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
    process.arguments = ["stream", "--level", "info", "--style", "compact",
                         "--predicate", #"subsystem == "io.github.st-eez.kosmos" AND category == "app""#]
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try! process.run()
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    Thread.detachNewThread {
        var buffer = Data()
        while true {
            let chunk = pipe.fileHandleForReading.availableData
            if chunk.isEmpty { return }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 10) {
                let line = String(decoding: buffer[..<newline], as: UTF8.self)
                buffer.removeSubrange(...newline)
                guard let match = line.firstMatch(of: #/^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d{3}).* (\d+) written, AX time/#),
                      let at = formatter.date(from: String(match.1)), let window = UInt32(match.2) else { continue }
                writes.add(window, at)
            }
        }
    }
    return process
}

/// The app's standard windows and their frames through Accessibility: the app's own frames,
/// where the window list's bounds follow Kosmos's slide transforms (docs/geometry.md).
private func frames(of pid: pid_t) -> [UInt32: (frame: CGRect, element: AXUIElement)] {
    var frames: [UInt32: (frame: CGRect, element: AXUIElement)] = [:]
    for window in axWindows(pid) {
        if let frame = axFrame(window.element) { frames[window.id] = (frame, window.element) }
    }
    return frames
}

private func text(_ frame: CGRect) -> String {
    "(\(Int(frame.minX)), \(Int(frame.minY)), \(Int(frame.width))x\(Int(frame.height)))"
}

@MainActor func snapBack(app name: String, seconds: Double, watchOnly: Bool) -> Never {
    NSApplication.shared.setActivationPolicy(.accessory)
    guard AXIsProcessTrusted() else { print("error: this terminal has no Accessibility permission"); exit(1) }
    let writes = KosmosWrites()
    let stream = streamKosmosWrites(into: writes)
    defer { stream.terminate() }
    let start = Date()
    func stamp(_ at: Date = Date()) -> String { String(format: "%7.3f s", at.timeIntervalSince(start)) }
    print("watching \(name) for \(Int(seconds)) s\(watchOnly ? ", writing nothing" : ""); open it and sign in with Bitwarden")

    var pid: pid_t = 0
    var last: [UInt32: CGRect] = [:], tile: [UInt32: CGRect] = [:]
    var pending: [Change] = []
    var ours: [(window: UInt32, at: Date)] = []
    var snaps: [UInt32: [Date]] = [:]
    var counts = (kosmos: 0, app: 0, snapped: 0, capped: 0)
    while Date().timeIntervalSince(start) < seconds {
        if pid == 0 || NSRunningApplication(processIdentifier: pid) == nil {
            let found = NSWorkspace.shared.runningApplications.first { $0.localizedName == name }?.processIdentifier ?? 0
            if found != pid {
                pid = found
                last = [:]
                if pid != 0 { print("\(stamp()) \(name) is pid \(pid)") }
            }
        }
        if pid != 0 {
            let now = Date(), seen = frames(of: pid)
            for (window, (frame, _)) in seen where last[window] != frame {
                if last[window] == nil {
                    print("\(stamp()) \(window) on screen at \(text(frame))")
                } else {
                    pending.append(Change(window: window, at: now, frame: frame))
                }
                last[window] = frame
            }
            for window in last.keys where seen[window] == nil {
                print("\(stamp()) \(window) off screen")
                last[window] = nil
            }
            // Decided 700 ms on, once the log has given Kosmos's writes around the change.
            let due = pending.filter { now.timeIntervalSince($0.at) >= 0.7 }
            pending.removeAll { now.timeIntervalSince($0.at) >= 0.7 }
            for change in due {
                let window = change.window
                if writes.near(window, change.at, within: 0.15) {
                    tile[window] = change.frame
                    counts.kosmos += 1
                    print("\(stamp(change.at)) \(window) Kosmos's write: tile \(text(change.frame))")
                    continue
                }
                if ours.contains(where: { $0.window == window && abs($0.at.timeIntervalSince(change.at)) <= 0.15 }) {
                    print("\(stamp(change.at)) \(window) took the write back: \(text(change.frame))")
                    continue
                }
                counts.app += 1
                if watchOnly {
                    print("\(stamp(change.at)) \(window) changed by its app to \(text(change.frame))"
                          + (tile[window].map { "; Kosmos's tile \(text($0))" } ?? "; no write of Kosmos's seen"))
                    continue
                }
                let button = CGEventSource.buttonState(.combinedSessionState, button: .left)
                guard let target = tile[window] else {
                    print("\(stamp(change.at)) \(window) changed to \(text(change.frame)), no tile of Kosmos's seen yet; left alone")
                    continue
                }
                guard change.frame != target else { continue }
                // Only a shrink at the tile's origin, as Alarm.com's on 2026-10-06: a move could
                // be a write of Kosmos's whose log line the probe missed.
                guard abs(change.frame.minX - target.minX) <= 2, abs(change.frame.minY - target.minY) <= 2,
                      change.frame.isSmaller(than: target) else {
                    print("\(stamp(change.at)) \(window) changed to \(text(change.frame)), not a shrink at its tile \(text(target)); left alone")
                    continue
                }
                guard !button else {
                    print("\(stamp(change.at)) \(window) changed to \(text(change.frame)) with the button down; left to Kosmos's mouse up")
                    continue
                }
                guard last[window] == change.frame else {
                    print("\(stamp(change.at)) \(window) changed to \(text(change.frame)), already changed again; the later change decides")
                    continue
                }
                let recent = (snaps[window] ?? []).filter { now.timeIntervalSince($0) < 5 }
                guard recent.count < 3 else {
                    counts.capped += 1
                    print("\(stamp(change.at)) \(window) changed to \(text(change.frame)) by its app again; 3 write backs in 5 s, left alone")
                    continue
                }
                guard let element = seen[window]?.element else {
                    print("\(stamp(change.at)) \(window) changed by its app to \(text(change.frame)); no Accessibility element")
                    continue
                }
                var size = target.size, origin = target.origin
                AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &size)!)
                AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &origin)!)
                AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &size)!)
                let wrote = Date()
                ours.append((window, wrote))
                snaps[window] = recent + [wrote]
                counts.snapped += 1
                let read = axFrame(element).map(text) ?? "unread"
                print("\(stamp(change.at)) \(window) changed by its app to \(text(change.frame)); written back to \(text(target)) "
                      + String(format: "%.0f ms later, read back %@", wrote.timeIntervalSince(change.at) * 1000, read))
            }
        }
        pumpEvents(0.015)
    }
    print("\(stamp()) end: \(counts.kosmos) changes of Kosmos's, \(counts.app) of the app's, \(counts.snapped) written back, \(counts.capped) left at the cap")
    stream.terminate()
    exit(0)
}
