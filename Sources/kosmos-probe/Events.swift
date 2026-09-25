// Which SkyLight events arrive, and when (docs/inventory.md).
//
//   kosmos-probe level [onscreen|opaque]  Whether WindowServer reports a change of a
//                                   window's level. An invisible window of its own goes to
//                                   the floating level and back three times, off every
//                                   display, or with onscreen in a corner of the main one;
//                                   opaque gives it full alpha. Prints every event in order.
//   kosmos-probe events [seconds]   Each event Kosmos registers, for 30 s by default, with the
//                                   unified log's clock, the window and its app. Opens no
//                                   window and takes no focus, so it runs beside Kosmos.
import AppKit
import CKosmos
import KosmosSkyLight

nonisolated(unsafe) var levelEvents: [(id: UInt32, at: Double, payload: [UInt8])] = []
/// Each change: when the child asked for it, and when WindowServer first read the new level.
nonisolated(unsafe) var levelSteps: [(at: Double, landed: Double, text: String)] = []

/// Like `hidden-window`, onscreen and opaque on request. Prints its id, then the uptime and
/// level of each change.
@MainActor func levelWindow() -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let origin = CommandLine.arguments.contains("onscreen") ? NSScreen.main?.visibleFrame.origin ?? .zero : NSPoint(x: -4000, y: -4000)
    let window = NSWindow(contentRect: NSRect(origin: origin, size: NSSize(width: 60, height: 60)),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.alphaValue = CommandLine.arguments.contains("opaque") ? 1 : 0
    window.ignoresMouseEvents = true
    window.orderFrontRegardless()
    print(window.windowNumber)
    for (step, level) in [NSWindow.Level.floating, .normal, .floating, .normal, .floating, .normal].enumerated() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(step + 1)) {
            let before = uptime()
            window.level = level
            print(String(format: "%.3f level %d", before, level.rawValue))
        }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 7.5) { exit(0) }
    app.run()
    exit(0)
}

@MainActor func levels() -> Never {
    // SkyLight delivers events inside a running AppKit event loop, as in Kosmos.
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let start = uptime()
    // Before the child starts, so the window's creation shows too. Ids below 750 include input
    // events (CGSInternal headers), which the probe leaves alone.
    let ids: Range<UInt32> = 750..<1800
    var registered = 0
    for id in ids {
        let result = SLSRegisterConnectionNotifyProc(SLSMainConnectionID(), { id, data, length, _, _ in
            let at = uptime()
            let payload = data == nil ? [] : [UInt8](UnsafeRawBufferPointer(start: data, count: length))
            DispatchQueue.main.async { levelEvents.append((id, at, payload)) }
        }, id, nil)
        if result == .success { registered += 1 }
    }
    let child = Child(["level-window"] + CommandLine.arguments.dropFirst(2))
    let window = child.readWindows()[0]
    SkyLight.watch([window])
    print("window \(window), pid \(child.pid); \(registered) of \(ids.count) notifications registered")
    child.onLines { line in
        let fields = line.split(separator: " ")   // "<uptime> level <level>"
        guard fields.count == 3, let at = Double(fields[0]), let level = Int32(fields[2]) else { return }
        // AppKit sends the level to WindowServer after the setter returns.
        var landed: Double?
        while landed == nil, uptime() - at < 500 {
            if SkyLight.rows([window]).first?.level == level { landed = uptime() } else { usleep(500) }
        }
        let text = "child sets level \(level); WindowServer reads it "
            + (landed.map { String(format: "%.1f ms later", $0 - at) } ?? "not within 500 ms")
        let step = (at: at, landed: landed ?? at, text: text)
        DispatchQueue.main.async { levelSteps.append(step) }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
        reportLevels(window, start: start)
        exit(0)
    }
    app.run()
    exit(0)
}

/// Events of other ids count as near a change from its request to 100 ms after WindowServer
/// read it.
@MainActor func reportLevels(_ window: UInt32, start: Double) {
    var timeline = levelSteps.map { (at: $0.at, text: $0.text) }
    var others: [(id: UInt32, at: Double)] = []
    for event in levelEvents {
        let offsets = stride(from: 0, to: event.payload.count - 3, by: 4).filter { offset in
            event.payload.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) } == window
        }
        let bytes = event.payload.prefix(32).map { String(format: "%02x", $0) }.joined()
        guard !offsets.isEmpty else {
            others.append((event.id, event.at))
            timeline.append((event.at, "  event \(event.id), not naming the window, payload \(bytes)"))
            continue
        }
        timeline.append((event.at, "event \(event.id), \(event.payload.count) bytes, window id at offset \(offsets), payload \(bytes)"))
    }
    for entry in timeline.sorted(by: { $0.at < $1.at }) { print(String(format: "%8.1f ms ", entry.at - start) + entry.text) }
    print("events of other ids, by whether they came from a request to 100 ms after WindowServer read the level (\(levelSteps.count) changes):")
    for (id, events) in Dictionary(grouping: others, by: \.id).sorted(by: { $0.key < $1.key }) {
        let near = events.filter { event in levelSteps.contains { event.at >= $0.at && event.at <= $0.landed + 100 } }.count
        print("  event \(id): \(near) near a change, \(events.count - near) at other times")
    }
    if others.isEmpty { print("  none") }
}

@MainActor func events(seconds: Double) -> Never {
    // SkyLight delivers events inside a running AppKit event loop, as in Kosmos.
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    WindowServerEvent.register(WindowServerEvent.ids) { id, window, payload in
        let at = Date()
        let bytes = payload.prefix(16).map { String(format: "%02x", $0) }.joined()
        DispatchQueue.main.async { MainActor.assumeIsolated { printEvent(id, window: window, payload: bytes, at: at) } }
    }
    let watched = SkyLight.allWindowIDs()
    SkyLight.watch(watched)
    print("watching \(watched.count) windows for \(seconds) s")
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exit(0) }
    app.run()
    exit(0)
}

/// Each app's name by pid, read once. Main thread only.
nonisolated(unsafe) var eventAppNames: [pid_t: String] = [:]

@MainActor func printEvent(_ id: UInt32, window: UInt32?, payload: String, at: Date) {
    var line = "\(wallClock.string(from: at)) \(id)"
    if let window {
        let pid = SkyLight.rows([window]).first?.pid
        let name = pid.map { pid in
            if let name = eventAppNames[pid] { return name }
            let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
            eventAppNames[pid] = name
            return name
        } ?? "gone"
        line += " window \(window) (\(name))"
    } else {
        line += " payload \(payload)"
    }
    print(line)
}
