// kosmos-probe mission-control [none|on-enter|always] [seconds]: can concealed windows be
// kept out of Mission Control by stripping their ordinary Space only while it is open
// (DESIGN.md, section 5.3)?
//
// A concealed window keeps its ordinary Space, and Mission Control shows it as an empty
// placeholder with its app's icon. The probe opens four windows in an accessory app, which
// Kosmos leaves alone, and conceals two of them in a holding Space as Kosmos does. It
// watches the Exposé notifications as yabai does (src/mission_control.c), on the Dock, where
// yabai watches them, and on WindowManager.app, which draws Mission Control on macOS 27 and
// contains the same names. It also watches WindowServer event 1204, which yabai reads for
// Mission Control before macOS 12. Each prints with the wall clock time.
//
// On the first run, with the Dock alone, no signal arrived while Mission Control opened
// twice, and at cleanup the holding Space held two windows of WindowManager's, which names
// its placeholders "App Icon Window" at layer 17. So the probe also prints two controls, which
// never strip: AXMenuOpened, which the Dock posts for a right click on one of its icons and
// which proves the observer path, and AXWindowCreated. It also prints each WindowServer event
// 1325 and 1326 that adds a window to the holding Space or removes one from it, with the
// window's app and level.
//
//   none      strips nothing: the concealed windows keep their ordinary Space throughout.
//   on-enter  strips them at the first enter signal of either kind and gives their ordinary
//             Space back at AXExposeExit, on a queue of its own as Kosmos's bridge queue.
//             Prints when each operation was sent, and when the windows' Spaces read it
//             done.
//   always    strips them as it conceals them, so they have no ordinary Space at all: the
//             reference for what Mission Control shows without the placeholders.
//
// It runs for 120 s by default. At the end, and on Ctrl-C or a hangup, the windows get their
// ordinary Space back and leave the holding Space, which is destroyed, and the app quits.
// Needs Accessibility for the terminal; the probe never asks for it.
import AppKit
import CKosmos
import KosmosSkyLight

private enum Strip: String {
    case never = "none"
    case onEnter = "on-enter"
    case always
}

/// The Exposé notifications, as yabai names them. The Dock and WindowManager.app of macOS 27
/// (26A428) contain the same four names.
private let enterNotifications = ["AXExposeShowAllWindows", "AXExposeShowFrontWindows", "AXExposeShowDesktop"]
private let exitNotification = "AXExposeExit"
private let controlNotifications = [kAXMenuOpenedNotification, kAXWindowCreatedNotification]

/// How long, in milliseconds, an operation's result is read before the probe gives up on it.
private let landingBound = 2000.0

@MainActor private var probe: MissionControlProbe?

@MainActor private let wallClock: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
    return formatter
}()

@MainActor func missionControl(_ arguments: [String]) -> Never {
    var strip = Strip.never, seconds = 120.0
    for argument in arguments {
        if let value = Double(argument) {
            seconds = value
        } else if let value = Strip(rawValue: argument) {
            strip = value
        } else {
            print("usage: kosmos-probe mission-control [none|on-enter|always] [seconds]")
            exit(2)
        }
    }
    guard AXIsProcessTrusted() else { print("this terminal needs Accessibility permission"); exit(1) }
    let watched = ["com.apple.dock", "com.apple.WindowManager"].compactMap {
        NSRunningApplication.runningApplications(withBundleIdentifier: $0).first
    }
    // Bridged operations need an AppKit client, and the notifications arrive in its event loop.
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)

    // M1 sits at the bottom right corner of the main display, and M2 to M4 to its left.
    let stub = KeyStub("M", ["0,0", "190,0", "380,0", "570,0"])
    Thread.sleep(forTimeInterval: 0.3)   // let the windows reach the screen
    let windows = [stub.windows[1], stub.windows[3]]
    let original = Dictionary(uniqueKeysWithValues: windows.map { ($0, (kosmos_window_spaces($0) as? [UInt64])?.first ?? 0) })
    let space = kosmos_holding_create()
    guard space != 0, !original.values.contains(0) else {
        print(space == 0 ? "holding Space not created" : "a window has no ordinary Space: \(original)")
        if space != 0 { kosmos_space_destroy(space) }
        stub.process.terminate()
        exit(1)
    }
    let concealed = Concealed(space: space, windows: windows, original: original,
                              labels: Dictionary(uniqueKeysWithValues: windows.map { ($0, stub.label($0)) }))
    var ids = windows
    kosmos_add_windows(space, &ids, ids.count, strip == .always)
    _ = kosmos_barrier(space)

    print("variant \(strip.rawValue), \(seconds) s; holding Space \(space)")
    print("from the bottom right corner of the main display leftward: "
          + stub.windows.map { "\(stub.label($0)) \($0) \(windows.contains($0) ? "concealed" : "shown")" }.joined(separator: ", "))
    print("concealed: \(concealed.membership())")
    probe = MissionControlProbe(strip: strip, stub: stub, concealed: concealed)
    for app in watched { probe!.watch(app) }
    probe!.watchHoldingSpace()
    probe!.handleSignals()
    print("open Mission Control, App Exposé and Show Desktop; Ctrl-C ends the probe")
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { probe?.finish("\(seconds) s passed") }
    app.run()
    exit(0)
}

/// The concealed windows and their holding Space. Its operations run on the bridge queue.
private struct Concealed: Sendable {
    let space: UInt64
    let windows: [UInt32]
    /// The ordinary Space each window had before its conceal.
    let original: [UInt32: UInt64]
    let labels: [UInt32: String]

    /// Takes the windows out of their ordinary Space with an exclusive add to the holding
    /// Space, which already has them. Returns the uptimes it sent the add and read it done.
    func strip() -> (start: Double, sent: Double, landed: Double?) {
        var ids = windows
        let start = uptime()
        kosmos_add_windows(space, &ids, ids.count, true)
        let sent = uptime()
        return (start, sent, landing { windows.allSatisfy { spaces($0)?.contains(original[$0]!) == false } })
    }

    /// Adds the windows to their ordinary Space again, keeping the holding Space. Returns the
    /// uptimes it sent the adds and read them done.
    func restore() -> (start: Double, sent: Double, landed: Double?) {
        let start = uptime()
        for (destination, group) in Dictionary(grouping: windows, by: { original[$0]! }) {
            var ids = group
            kosmos_add_windows(destination, &ids, ids.count, false)
        }
        let sent = uptime()
        return (start, sent, landing { windows.allSatisfy { spaces($0)?.contains(original[$0]!) == true } })
    }

    /// Each window's ordinary Spaces and whether the holding Space has it.
    func membership() -> String {
        windows.map { "\(labels[$0]!) Spaces \(spaces($0).map { "\($0)" } ?? "unread"), in holding \(inSpace($0, space))" }
            .joined(separator: "; ")
    }

    private func spaces(_ window: UInt32) -> [UInt64]? { kosmos_window_spaces(window) as? [UInt64] }

    /// The uptime at which `done` first held, read every 0.1 ms, or nil after landingBound.
    private func landing(_ done: () -> Bool) -> Double? {
        let start = uptime()
        while !done() {
            guard uptime() - start < landingBound else { return nil }
            usleep(100)
        }
        return uptime()
    }
}

@MainActor private final class MissionControlProbe {
    private let strip: Strip
    private let stub: KeyStub
    private let concealed: Concealed
    /// Runs the operations in order, off the main thread, as Kosmos's bridge queue does.
    private let bridge = DispatchQueue(label: "kosmos-probe.mission-control")
    private var observers: [AXObserver] = []
    private var names: [pid_t: String] = [:]
    private var signalSources: [DispatchSourceSignal] = []
    /// The uptime of the first enter signal since the last exit.
    private var opened: Double?
    private var stripped = false

    init(strip: Strip, stub: KeyStub, concealed: Concealed) {
        (self.strip, self.stub, self.concealed) = (strip, stub, concealed)
    }

    func watch(_ app: NSRunningApplication) {
        let pid = app.processIdentifier, name = app.localizedName ?? "pid \(pid)"
        names[pid] = name
        var created: AXObserver?
        guard AXObserverCreate(pid, { _, element, notification, _ in
            let at = uptime()
            var pid: pid_t = 0
            AXUIElementGetPid(element, &pid)
            MainActor.assumeIsolated { probe?.notice(notification as String, from: pid, at: at) }
        }, &created) == .success, let observer = created else { finish("no Accessibility observer for \(name)") }
        let element = AXUIElementCreateApplication(pid)
        for notification in enterNotifications + [exitNotification] + controlNotifications {
            let result = AXObserverAddNotification(observer, element, notification as CFString, nil)
            print("\(name) \(notification): \(result == .success ? "registered" : "not registered, AXError \(result.rawValue)")")
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers.append(observer)
    }

    /// Prints each window that joins or leaves the holding Space.
    func watchHoldingSpace() {
        let result = SLSRegisterConnectionNotifyProc(SLSMainConnectionID(), { _, _, _, _, _ in
            let at = uptime()
            DispatchQueue.main.async { MainActor.assumeIsolated { probe?.notice("WindowServer event 1204", from: 0, at: at) } }
        }, 1204, nil)
        print("WindowServer event 1204: \(result == .success ? "registered" : "not registered, CGError \(result.rawValue)")")
        for id: UInt32 in [1325, 1326] {
            SLSRegisterConnectionNotifyProc(SLSMainConnectionID(), { id, data, length, _, _ in
                let bytes = UnsafeRawBufferPointer(start: data, count: data == nil ? 0 : length)
                guard bytes.count >= 12 else { return }
                let space = bytes.loadUnaligned(fromByteOffset: 0, as: UInt64.self)
                let window = bytes.loadUnaligned(fromByteOffset: 8, as: UInt32.self)
                DispatchQueue.main.async { MainActor.assumeIsolated { probe?.membershipChanged(id, window, space) } }
            }, id, nil)
        }
    }

    func membershipChanged(_ id: UInt32, _ window: UInt32, _ space: UInt64) {
        guard space == concealed.space else { return }
        let row = SkyLight.rows([window]).first
        let app = row.map { NSRunningApplication(processIdentifier: $0.pid)?.localizedName ?? "pid \($0.pid)" } ?? "gone"
        print("\(wallClock.string(from: Date())) WindowServer event \(id): window \(window) (\(app), level \(row.map { "\($0.level)" } ?? "unread")) "
              + (id == 1325 ? "joined" : "left") + " the holding Space")
    }

    /// Ctrl-C, a kill and a closed terminal clean up as the timeout does.
    func handleSignals() {
        for number in [SIGINT, SIGTERM, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { MainActor.assumeIsolated { probe?.finish("signal \(number)") } }
            source.resume()
            signalSources.append(source)
        }
    }

    /// A notification from the process `pid`, or WindowServer's when 0, that arrived at the
    /// uptime `at`.
    func notice(_ notification: String, from pid: pid_t, at: Double) {
        let stamp = wallClock.string(from: Date())
        let name = pid == 0 ? notification : "\(names[pid] ?? "pid \(pid)") \(notification)"
        if controlNotifications.contains(notification) { return print(stamp + " " + name + " (control)") }
        let concealed = self.concealed
        if notification == exitNotification {
            print(stamp + " " + name + (opened.map { String(format: ", %.0f ms after the first enter signal", at - $0) } ?? ", with no enter signal before it"))
            opened = nil
            guard stripped else { return }
            stripped = false
            bridge.async { Self.report("restore", concealed.restore(), after: at, concealed) }
            return
        }
        print(stamp + " " + name + (opened.map { String(format: ", %.0f ms after the first enter signal", at - $0) } ?? ""))
        if opened == nil { opened = at }
        if strip == .onEnter && !stripped {
            stripped = true
            bridge.async { Self.report("strip", concealed.strip(), after: at, concealed) }
        } else {
            bridge.async { print("  concealed: \(concealed.membership())") }
        }
    }

    private nonisolated static func report(_ operation: String, _ timing: (start: Double, sent: Double, landed: Double?),
                                           after signal: Double, _ concealed: Concealed) {
        let landed = timing.landed.map { String(format: "read done %.2f ms after the signal", $0 - signal) }
            ?? String(format: "not read done within %.0f ms", landingBound)
        print(String(format: "  %@ sent %.2f ms after the signal, the call took %.2f ms, ", operation,
                     timing.start - signal, timing.sent - timing.start) + landed + "; " + concealed.membership())
    }

    /// Gives every window its ordinary Space back, empties and destroys the holding Space, and
    /// quits the windows' app.
    func finish(_ reason: String) -> Never {
        print("\(reason); cleaning up")
        let concealed = self.concealed
        bridge.sync {
            // A window removed from its only Space lands on the active Space, so each gets its
            // ordinary Space back before it leaves the holding Space.
            let restored = concealed.restore()
            _ = kosmos_barrier(concealed.space)
            var ids = concealed.windows
            kosmos_remove_windows(concealed.space, &ids, ids.count)
            _ = kosmos_barrier(concealed.space)
            let left = (kosmos_space_windows(concealed.space) as? [UInt32]).map { "\($0)" } ?? "unread"
            print("ordinary Spaces \(restored.landed == nil ? "NOT back" : "back"); \(concealed.membership()); holding Space members \(left)")
            print("holding Space \(concealed.space) destroyed: \(kosmos_space_destroy(concealed.space))")
        }
        stub.process.terminate()
        exit(0)
    }
}
