// Whether ending the observation of an app's activation policy at the app's exit, as Kosmos's
// inventory does, leaves AppKit a freed instance to message (docs/inventory.md).
//
//   kosmos-probe policy-exits [cycles] [tuple]
//                                   Runs cycles children, 300 by default, 4 at a time. Each
//                                   launches as an accessory app with no window, makes 0 to 3
//                                   changes of its activation policy 20 ms apart and exits: in
//                                   the run loop turn of its last change in every other group
//                                   of 4 cycles, and 20 ms later otherwise. Its first change is
//                                   to regular in every other group of 8 cycles and to
//                                   prohibited otherwise, and each next one goes back and forth
//                                   to accessory. The probe finds each child by pid, observes
//                                   its activationPolicy and ends the observation at the
//                                   child's exit source, with a class that holds the app and
//                                   ends the observation in its deinit, as Kosmos does. The
//                                   other children's changes keep LaunchServices calling AppKit
//                                   back throughout. Prints the counts, and how many instances
//                                   AppKit logged as freed while observed. Sends no input and
//                                   takes no focus. A child that is regular shows in the Dock.
//                                   tuple holds each app and its observation in a tuple and
//                                   ends them as the policyfix merge (6a9a3df) did, which
//                                   crashed Kosmos on September 28, 2026.
import AppKit
import OSLog

/// Launches as an accessory app, makes each change 20 ms after the last, and exits, in the
/// run loop turn of the last change when `atOnce`.
@MainActor func policyFlips(_ changes: [NSApplication.ActivationPolicy], atOnce: Bool) -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    func run(_ index: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            guard index < changes.count else { exit(0) }
            app.setActivationPolicy(changes[index])
            if index == changes.count - 1, atOnce { exit(0) }
            run(index + 1)
        }
    }
    run(0)
    app.run()
    exit(0)
}

@MainActor func policyExits(cycles: Int, tuple: Bool) -> Never {
    NSApplication.shared.setActivationPolicy(.accessory)   // as Kosmos is
    let probe = PolicyExits(cycles: cycles, tuple: tuple)
    for _ in 0..<4 { probe.launch() }
    withExtendedLifetime(probe) { NSApplication.shared.run() }
    exit(0)
}

/// Kosmos's PolicyWatch: the observation ends in the deinit, while the app is still held.
private final class PolicyWatch {
    let app: NSRunningApplication
    private let observation: NSKeyValueObservation

    init(_ app: NSRunningApplication, changed: @escaping @Sendable () -> Void) {
        self.app = app
        observation = app.observe(\.activationPolicy) { _, _ in changed() }
    }

    deinit { observation.invalidate() }
}

@MainActor private final class PolicyExits {
    private let cycles: Int
    private let tuple: Bool
    private let began = Date()
    private var launched = 0, found = 0, exits = 0, atOnce = 0, made = 0, observed = 0
    private var children: [pid_t: Child] = [:]
    private var sources: [pid_t: any DispatchSourceProcess] = [:]
    private var watches: [pid_t: PolicyWatch] = [:]
    private var tupleWatches: [pid_t: (app: NSRunningApplication, observation: NSKeyValueObservation)] = [:]

    init(cycles: Int, tuple: Bool) {
        self.cycles = cycles
        self.tuple = tuple
    }

    func launch() {
        guard launched < cycles else { return }
        let cycle = launched
        launched += 1
        let first: NSApplication.ActivationPolicy = cycle / 8 % 2 == 0 ? .regular : .prohibited
        let changes = [first, .accessory, first].prefix(cycle % 4)
        let exitsAtOnce = !changes.isEmpty && cycle / 4 % 2 == 0
        made += changes.count
        if exitsAtOnce { atOnce += 1 }
        let child = Child(["policy-flips"] + changes.map(policyName) + (exitsAtOnce ? ["at-once"] : []))
        let pid = child.pid
        children[pid] = child
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { self.exited(pid) } }
        sources[pid] = source
        source.resume()
        find(pid)
    }

    /// Polls, as the probe knows the pid before LaunchServices does, until the child exits.
    private func find(_ pid: pid_t) {
        guard children[pid] != nil else { return }
        guard let app = NSRunningApplication(processIdentifier: pid) else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.002) { MainActor.assumeIsolated { self.find(pid) } }
            return
        }
        found += 1
        let changed: @Sendable () -> Void = { DispatchQueue.main.async { MainActor.assumeIsolated { self.observed += 1 } } }
        if tuple {
            tupleWatches[pid] = (app, app.observe(\.activationPolicy) { _, _ in changed() })
        } else {
            watches[pid] = PolicyWatch(app, changed: changed)
        }
        // Kosmos reads the policy once it observes it.
        _ = app.activationPolicy
    }

    private func exited(_ pid: pid_t) {
        exits += 1
        sources.removeValue(forKey: pid)?.cancel()
        if tuple {
            // The policyfix merge's statement, which released the app before the observation ended.
            tupleWatches.removeValue(forKey: pid)?.observation.invalidate()
        } else {
            watches[pid] = nil
        }
        children[pid] = nil
        launch()
        if children.isEmpty { report() }
    }

    private func report() {
        let logged = appKitLog()
        print("""
            policy-exits: \(cycles) children, 4 at a time, each observation ended \
            \(tuple ? "as the policyfix merge did" : "by the deinit of a class that holds the app")
              found by pid before they exited: \(found)
              changes made after launch: \(made); observations, which count the change at launch too: \(observed)
              exits in the run loop turn of a change: \(atOnce)
              exit sources handled: \(exits)
              instances AppKit logged as freed while observed: \(logged.map { String($0.freed) } ?? "log unreadable")
              AppKit callbacks that threw: \(logged.map { String($0.threw) } ?? "log unreadable")
              took \(String(format: "%.1f", Date().timeIntervalSince(began))) s, no crash
            """)
        exit(0)
    }

    /// NSRunningApplication logs its dealloc while observed and leaves itself in the table that
    /// LaunchServices' notifications walk. AppKit logs an exception that walk throws, as when a
    /// freed instance's memory holds another object, and skips the rest of the notification.
    private func appKitLog() -> (freed: Int, threw: Int)? {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier),
              let entries = try? store.getEntries(at: store.position(date: began)) else { return nil }
        let messages = entries.map(\.composedMessage)
        return (messages.filter { $0.contains("is being deallocated while observers are still registered") }.count,
                messages.filter { $0.contains("Ignoring exception thrown from NSRunningApplication callback") }.count)
    }
}
