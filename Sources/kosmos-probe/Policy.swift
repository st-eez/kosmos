// How another process sees an app change its activation policy while it runs, as RustDesk's
// remote desktop process does (docs/inventory.md).
//
//   kosmos-probe policy [rounds] [bundle]
//                                   Each round, 4 by default, a child launches as an accessory
//                                   app. 1 s later it becomes regular and, in the same turn,
//                                   orders in a floating utility panel at the bottom left of the
//                                   built-in display, which no Kosmos build manages. 1 s later it
//                                   goes back to accessory. In odd rounds it becomes regular
//                                   again 1 s later. Each child exits 1 s after its last change.
//                                   Prints the cost of observing every running app's
//                                   activationPolicy, then for each round, on one clock, the
//                                   child's steps, NSWorkspace's launch and terminate
//                                   notifications for it with the policy they carry, its entries
//                                   in runningApplications, each key-value observation of
//                                   activationPolicy on the instance each of those gave and on
//                                   one from NSRunningApplication(processIdentifier:), and
//                                   WindowServer's creation and Space events for its window,
//                                   with the policy a fresh read gives there. bundle runs the
//                                   child from an app bundle whose Info.plist sets LSUIElement,
//                                   as RustDesk's does; otherwise the child sets .accessory
//                                   before it finishes launching. Sends no input and takes no
//                                   focus.
import AppKit
import KosmosSkyLight

/// Prints each step with its uptime. `exitsRegular`: regular again before it exits.
@MainActor func policyWindow(exitsRegular: Bool) -> Never {
    let app = NSApplication.shared
    if Bundle.main.object(forInfoDictionaryKey: "LSUIElement") == nil { app.setActivationPolicy(.accessory) }
    let say = { (text: String) in print(String(format: "%.3f ", uptime()) + text) }
    say("launches as \(policyName(app.activationPolicy()))")
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
        say("becomes regular")
        let changed = app.setActivationPolicy(.regular)
        let area = builtInScreen().visibleFrame
        // The probe's windows showed at level 0 for 30 to 50 ms before their level landed, and
        // Kosmos took them for candidates then, so this is a utility panel, which it never manages.
        let window = NSPanel(contentRect: NSRect(x: area.minX + 20, y: area.minY + 20, width: 240, height: 120),
                             styleMask: [.titled, .utilityWindow], backing: .buffered, defer: false)
        window.title = "kosmos-probe policy"
        window.level = .floating
        window.orderFrontRegardless()
        say("regular \(changed), window \(window.windowNumber) ordered in")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            say("becomes accessory")
            say("accessory \(app.setActivationPolicy(.accessory))")
            guard exitsRegular else {
                return DispatchQueue.main.asyncAfter(deadline: .now() + 1) { say("exits"); exit(0) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                say("becomes regular")
                say("regular \(app.setActivationPolicy(.regular))")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { say("exits"); exit(0) }
            }
        }
    }
    app.run()
    exit(0)
}

@MainActor func policy(rounds: Int, bundled: Bool) -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)   // as Kosmos is
    let bundle = bundled ? uiElementBundle() : nil
    let probe = PolicyProbe(executable: bundle.map { $0.appendingPathComponent("KosmosProbePolicy.app/Contents/MacOS/kosmos-probe") })
    probe.start()
    probe.run(1, of: rounds) {
        if let bundle { try? FileManager.default.removeItem(at: bundle) }
        exit(0)
    }
    app.run()
    exit(0)
}

func policyName(_ policy: NSApplication.ActivationPolicy) -> String {
    switch policy {
    case .regular: "regular"
    case .accessory: "accessory"
    case .prohibited: "prohibited"
    @unknown default: "unknown"
    }
}

/// A copy of the probe in an app bundle whose Info.plist sets LSUIElement.
private func uiElementBundle() -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("kosmos-probe-policy-\(getpid())")
    let contents = root.appendingPathComponent("KosmosProbePolicy.app/Contents")
    try! FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
    let info: [String: Any] = [
        "CFBundleIdentifier": "io.github.st-eez.kosmos.probe-policy", "CFBundleExecutable": "kosmos-probe",
        "CFBundleName": "KosmosProbePolicy", "CFBundlePackageType": "APPL", "LSUIElement": true,
    ]
    try! PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        .write(to: contents.appendingPathComponent("Info.plist"))
    try! FileManager.default.copyItem(at: Bundle.main.executableURL!, to: contents.appendingPathComponent("MacOS/kosmos-probe"))
    return root
}

@MainActor private final class PolicyProbe {
    private let executable: URL?
    private var child: Child?
    private var spawned = 0.0
    private var entries: [(at: Double, text: String)] = []
    /// The instances observed this round, by where each came from.
    private var instances: [(source: String, app: NSRunningApplication)] = []
    private var observations: [NSKeyValueObservation] = []
    private var listObservation: NSKeyValueObservation?
    private var switched: [(policy: NSApplication.ActivationPolicy, at: Double)] = []
    private var observed: [(source: String, policy: NSApplication.ActivationPolicy, at: Double)] = []
    private var created: (at: Double, fresh: String)?
    private var window: UInt32?
    /// Creation events whose window's row did not read then.
    private var unread811: [(window: UInt32, at: Double)] = []

    init(executable: URL?) { self.executable = executable }

    private var pid: pid_t? { child?.pid }

    private func note(_ text: String, at: Double = uptime()) { entries.append((at, text)) }

    func start() {
        let began = uptime()
        let running = NSWorkspace.shared.runningApplications
        let listed = uptime()
        let all = running.map { $0.observe(\.activationPolicy, options: [.new]) { _, _ in } }
        let observedAll = uptime()
        all.forEach { $0.invalidate() }
        print(String(format: "runningApplications: %d apps in %.2f ms; observing each one's activationPolicy took %.2f ms",
                     running.count, listed - began, observedAll - listed))
        let center = NSWorkspace.shared.notificationCenter
        for (name, label) in [(NSWorkspace.didLaunchApplicationNotification, "launch"),
                              (NSWorkspace.didTerminateApplicationNotification, "terminate"),
                              (NSWorkspace.didActivateApplicationNotification, "activate")] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                MainActor.assumeIsolated { self?.notified(label, app) }
            }
        }
        listObservation = NSWorkspace.shared.observe(\.runningApplications, options: [.old, .new]) { [weak self] _, change in
            let at = uptime(), main = Thread.isMainThread
            let added = change.newValue ?? [], removed = change.oldValue ?? []
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.listed(added: added, removed: removed, at: at, main: main) } }
        }
        WindowServerEvent.register([811, 1325, 1326]) { [weak self] id, window, _ in
            let at = uptime()
            guard let window else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.windowEvent(id, window, at: at) } }
        }
        // With an empty watch list no 811 came, for any window (2026-09-27).
        SkyLight.watch(SkyLight.allWindowIDs() ?? [])
    }

    func run(_ round: Int, of rounds: Int, done: @escaping @MainActor () -> Void) {
        guard round <= rounds else { return done() }
        entries = []
        observations.forEach { $0.invalidate() }
        observations = []
        instances = []
        switched = []
        observed = []
        created = nil
        window = nil
        unread811 = []
        spawned = uptime()
        let child = Child(["policy-window"] + (round % 2 == 1 ? ["regular"] : []), executable: executable)
        self.child = child
        note("spawned pid \(child.pid)", at: spawned)
        child.onLines { line in
            let fields = line.split(separator: " ", maxSplits: 1)
            guard fields.count == 2, let at = Double(fields[0]) else { return }
            let text = String(fields[1])
            DispatchQueue.main.async { MainActor.assumeIsolated { self.childSaid(text, at: at) } }
        }
        findByPid(child.pid, until: spawned + 3000)
        child.process.terminationHandler = { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MainActor.assumeIsolated {
                    self.report(round)
                    self.run(round + 1, of: rounds, done: done)
                }
            }
        }
    }

    private func childSaid(_ text: String, at: Double) {
        note("child: " + text, at: at)
        if text == "becomes regular" { switched.append((.regular, at)) }
        if text == "becomes accessory" { switched.append((.accessory, at)) }
        if text.hasPrefix("regular "), let id = text.split(separator: " ").dropFirst(3).first.flatMap({ UInt32($0) }) { window = id }
    }

    /// The probe polls, as it knows the pid before LaunchServices does. Kosmos cannot.
    private func findByPid(_ pid: pid_t, until end: Double) {
        guard pid == self.pid else { return }
        if let app = NSRunningApplication(processIdentifier: pid) { return observe(app, from: "by pid") }
        guard uptime() < end else { return note("NSRunningApplication(processIdentifier:) stayed nil for 3 s") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.005) { MainActor.assumeIsolated { self.findByPid(pid, until: end) } }
    }

    private func notified(_ label: String, _ app: NSRunningApplication) {
        guard app.processIdentifier == pid else { return }
        note("\(label) notification, policy \(policyName(app.activationPolicy))")
        if label == "launch" { observe(app, from: "launch notification") }
    }

    private func listed(added: [NSRunningApplication], removed: [NSRunningApplication], at: Double, main: Bool) {
        for app in added where app.processIdentifier == pid {
            note("runningApplications gains it, policy \(policyName(app.activationPolicy))\(main ? "" : ", off the main thread")", at: at)
            observe(app, from: "runningApplications")
        }
        for app in removed where app.processIdentifier == pid { note("runningApplications loses it", at: at) }
    }

    private func observe(_ app: NSRunningApplication, from source: String) {
        let same = instances.first { $0.app === app }?.source
        note("\(source) gives an instance\(same.map { ", the one \($0) gave" } ?? ""), policy \(policyName(app.activationPolicy))")
        guard same == nil else { return }
        instances.append((source, app))
        observations.append(app.observe(\.activationPolicy, options: [.new]) { [weak self] app, _ in
            let at = uptime(), main = Thread.isMainThread
            let policy = app.activationPolicy
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.changed(source, policy, at: at, main: main) } }
        })
    }

    private func changed(_ source: String, _ policy: NSApplication.ActivationPolicy, at: Double, main: Bool) {
        note("KVO on the instance \(source) gave: \(policyName(policy))\(main ? "" : ", off the main thread")", at: at)
        observed.append((source, policy, at))
    }

    private func windowEvent(_ id: UInt32, _ window: UInt32, at: Double) {
        let owner = SkyLight.rows([window])?.first?.pid
        if id == 811, owner == nil { unread811.append((window, at)) }
        guard let pid, owner == pid else { return }
        let fresh = NSRunningApplication(processIdentifier: pid).map { policyName($0.activationPolicy) } ?? "no app"
        let held = instances.map { "\($0.source) \(policyName($0.app.activationPolicy))" }.joined(separator: ", ")
        note("WindowServer \(id) for window \(window); a fresh read says \(fresh); held instances say \(held.isEmpty ? "none" : held)", at: at)
        if id == 811, created == nil { created = (at, fresh) }
    }

    private func report(_ round: Int) {
        print("round \(round), pid \(pid ?? 0), window \(window.map(String.init) ?? "?"):")
        for entry in entries.sorted(by: { $0.at < $1.at }) {
            print(String(format: "  %8.1f ms  ", entry.at - spawned) + entry.text)
        }
        for (policy, from) in switched {
            let each = instances.map { instance in
                let first = observed.first { $0.source == instance.source && $0.policy == policy && $0.at >= from }
                return "\(instance.source) " + (first.map { String(format: "%+.1f ms", $0.at - from) } ?? "never")
            }
            print(String(format: "  KVO after the child became %@ at %.1f ms: ", policyName(policy), from - spawned)
                  + (each.isEmpty ? "no instance" : each.joined(separator: ", ")))
        }
        for event in unread811 where event.window == window {
            print(String(format: "  WindowServer 811 for the window at %.1f ms, when its row did not read", event.at - spawned))
        }
        if let created, let from = switched.first?.at {
            print(String(format: "  created event %+.1f ms after the first switch to regular; a fresh read there said ", created.at - from) + created.fresh)
        } else {
            print("  no created event")
        }
    }
}
