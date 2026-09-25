// kosmos-probe mission-control [none|on-enter|always] [seconds]: can concealed windows be
// kept out of Mission Control by stripping their ordinary Space only while it is open
// (DESIGN.md, section 5.3)?
//
// A concealed window keeps its ordinary Space, and Mission Control shows it as an empty
// placeholder with its app's icon. The probe opens four windows in an accessory app, which
// Kosmos leaves alone, and conceals two of them in a holding Space as Kosmos does. It
// watches the Dock's Exposé notifications as yabai does (src/mission_control.c), and
// WindowServer event 1204, which yabai reads for Mission Control before macOS 12. Each
// prints with the wall clock time.
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

private enum Strip: String {
    case never = "none"
    case onEnter = "on-enter"
    case always
}

/// The Dock's Exposé notifications, as yabai names them. The Dock of macOS 27 (26A428)
/// contains the same four names.
private let enterNotifications = ["AXExposeShowAllWindows", "AXExposeShowFrontWindows", "AXExposeShowDesktop"]
private let exitNotification = "AXExposeExit"

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
    guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
        print("the Dock is not running")
        exit(1)
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
    probe!.watch(dock: dock.processIdentifier)
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
    private var observer: AXObserver?
    private var signalSources: [DispatchSourceSignal] = []
    /// The uptime of the first enter signal since the last exit.
    private var opened: Double?
    private var stripped = false

    init(strip: Strip, stub: KeyStub, concealed: Concealed) {
        (self.strip, self.stub, self.concealed) = (strip, stub, concealed)
    }

    func watch(dock: pid_t) {
        var created: AXObserver?
        guard AXObserverCreate(dock, { _, _, notification, _ in
            let at = uptime()
            MainActor.assumeIsolated { probe?.notice(notification as String, at: at) }
        }, &created) == .success, let observer = created else { finish("no Accessibility observer for the Dock") }
        let element = AXUIElementCreateApplication(dock)
        for name in enterNotifications + [exitNotification] {
            let result = AXObserverAddNotification(observer, element, name as CFString, nil)
            print("\(name): \(result == .success ? "registered" : "not registered, AXError \(result.rawValue)")")
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        self.observer = observer
        let result = SLSRegisterConnectionNotifyProc(SLSMainConnectionID(), { _, _, _, _, _ in
            let at = uptime()
            DispatchQueue.main.async { MainActor.assumeIsolated { probe?.notice("WindowServer event 1204", at: at) } }
        }, 1204, nil)
        print("WindowServer event 1204: \(result == .success ? "registered" : "not registered, CGError \(result.rawValue)")")
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

    /// An enter or exit signal that arrived at the uptime `at`.
    func notice(_ name: String, at: Double) {
        let stamp = wallClock.string(from: Date())
        let concealed = self.concealed
        if name == exitNotification {
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
