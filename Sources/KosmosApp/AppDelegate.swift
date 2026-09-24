import AppKit
import KosmosCore
import KosmosIPC
import KosmosRecovery
import KosmosSkyLight
import os

let log = Logger(subsystem: "io.github.st-eez.kosmos", category: "app")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var instanceLock: FileLock?
    private var record: RecordFile?
    private var statusItem: StatusItem?
    private var onboarding: Onboarding?
    private let inventory = Inventory()
    private let guardian = Guardian()
    private let lockWatch = LockWatch()
    private var signalSources: [DispatchSourceSignal] = []
    private var controller: Controller?
    private var server: IPCServer?
    private var hotkeys: Hotkeys?
    /// False while another tiling window manager runs.
    private var managing = false
    private var configProblems: [String] = []
    private var hotkeyProblems: [String] = []
    private var hidingProblem: String?
    private var focusProblem: String?
    private var hiding: Hiding?
    private var secureInput: SecureInput?
    /// The config that applies, for display changes.
    private var config = Config()
    /// The profile `profile` applied, until the displays change or the config reloads.
    private var forcedProfile: String?
    /// The displays read last, to tell a change of displays from one of their areas.
    private var displayIDs: Set<DisplayID> = []
    /// Numbers the display change notifications, so a burst gets one response.
    private var displayChanges = 0
    private var screensAsleep = false
    private static let defaultWorkspaces = (1...9).map(String.init)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // First, so a SIGTERM during the lock wait or startup recovery waits on the main queue
        // and quits Kosmos with exit 0 once startup is done. Killed by the signal, Kosmos
        // would count as crashed, and launch at login would restart it.
        handleTerminationSignals()
        do {
            // The lock keeps a second Kosmos out and serializes recovery with the guardian,
            // which holds it for up to about a second after a crash.
            var acquired = try FileLock(KosmosFiles.lock)
            for _ in 0..<60 where acquired == nil {
                usleep(50_000)
                acquired = try FileLock(KosmosFiles.lock)
            }
            guard let lock = acquired else {
                // launchd restarts the login agent after a failed start, which suits a lock the
                // guardian still holds. While another Kosmos runs, this one exits successfully,
                // so launchd leaves the agent stopped. The guardian has no bundle identifier.
                let running = NSRunningApplication.runningApplications(withBundleIdentifier: "io.github.st-eez.kosmos")
                    .contains { $0 != NSRunningApplication.current }
                log.error("\(running ? "another Kosmos is running" : "the instance lock is still held", privacy: .public)")
                exit(running ? 0 : 1)
            }
            instanceLock = lock
            let record = try RecordFile(url: KosmosFiles.record)
            self.record = record
            // Windows a previous run left concealed come back before anything else.
            log.notice("startup recovery: \(String(describing: Recovery.run(file: record)), privacy: .public)")
        } catch {
            log.error("\(error.localizedDescription, privacy: .public)")
            exit(1)
        }
        guardian.start()
        startServer()

        let statusItem = StatusItem()
        self.statusItem = statusItem
        SkyLight.watchSecureInput { [weak self] in self?.secureInputChanged() }
        secureInputChanged()
        lockWatch.onChange = { [weak self] locked in self?.lockChanged(locked) }
        lockWatch.start()
        // WindowServer tracking needs no permission, so it starts before the Accessibility grant.
        inventory.start()
        if AXIsProcessTrusted() {
            start()
        } else {
            statusItem.accessibilityMissing = true
            onboarding = Onboarding { [weak self] in self?.accessibilityGranted() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        server?.stop()
        // Through Hiding when it exists, so batches still queued land first.
        let outcome = hiding?.recoverNow() ?? record.map { Recovery.run(file: $0) }
        if let outcome { log.notice("quit recovery: \(String(describing: outcome), privacy: .public)") }
    }

    /// The socket starts after the instance lock, which rules out a live server at its path.
    private func startServer() {
        do {
            server = try IPCServer(socketPath: kosmosSocketPath(), log: { message in
                log.notice("ipc: \(message, privacy: .public)")
            }) { [weak self] arguments in
                self?.respond(to: arguments, received: .now) ?? Response(exitCode: 1, stderr: "kosmos: shutting down")
            }
        } catch {
            log.error("socket not started: \(String(describing: error), privacy: .public)")
        }
    }

    /// One entry point for the socket and the hotkeys.
    private func respond(to arguments: [String], received: ContinuousClock.Instant) -> Response {
        switch arguments {
        case ["ping"]: return Response(stdout: "pong")
        case ["version"]: return Response(stdout: kosmosVersion)
        case ["reload-config"]:
            guard controller != nil else { return Response(exitCode: 1, stderr: "kosmos: waiting for Accessibility permission") }
            guard managing else { return Response(exitCode: 1, stderr: "kosmos: observing only while another window manager runs") }
            controller?.turnOnPrivateFocus()
            let (applied, messages) = reloadConfig(atLaunch: false)
            return Response(exitCode: applied ? 0 : 1, stderr: messages.joined(separator: "\n"))
        default:
            switch Command.parse(arguments) {
            case .success(.mode(let name)): return switchMode(to: name)
            case .success(.profile(let name)): return applyProfile(name)
            default: break
            }
            guard let controller else {
                return Response(exitCode: 1, stderr: "kosmos: waiting for Accessibility permission")
            }
            let result = controller.run(arguments, received: received)
            return result.code == 0 ? Response(stdout: result.text) : Response(exitCode: result.code, stderr: "kosmos: " + result.text)
        }
    }

    private func switchMode(to name: String) -> Response {
        guard let hotkeys else { return Response(exitCode: 1, stderr: "kosmos: no hotkeys are registered") }
        // The command reports its own problems; the status item keeps the ones a load found,
        // so its icon never changes during a command.
        let problems = hotkeys.switchMode(to: name)
        for problem in problems { log.error("hotkey: \(problem.description, privacy: .public)") }
        return problems.isEmpty ? Response() : Response(exitCode: 1, stderr: problems.map(\.description).joined(separator: "\n"))
    }

    /// Applies a profile from the config until the displays change or the config reloads, as
    /// `set-profile.sh` did (DESIGN.md, section 5.13).
    private func applyProfile(_ name: String) -> Response {
        guard controller != nil else { return Response(exitCode: 1, stderr: "kosmos: waiting for Accessibility permission") }
        guard managing else { return Response(exitCode: 1, stderr: "kosmos: observing only while another window manager runs") }
        guard config.profiles.contains(where: { $0.name == name }) else {
            return Response(exitCode: 1, stderr: "kosmos: no profile named '\(name)'")
        }
        forcedProfile = name
        applyDisplays()
        return Response()
    }

    /// Reads the displays and applies the profile for them, or the one `profile` applied
    /// while they stay the same. Displays no profile fits keep the profile that applies
    /// (DESIGN.md, section 5.13). `resync`: conceal, reveal and focus
    /// every window again; the first apply at launch leaves them to the inventory. With no
    /// display at all, as in the middle of a change, the ones read before stay.
    private func applyDisplays(resync: Bool = true) {
        guard let controller else { return }
        let displays = ConfigFile.displays()
        guard !displays.isEmpty else { return log.notice("no displays listed; the ones read before stay") }
        let ids = Set(displays.map(\.id))
        if ids != displayIDs {
            if let forced = forcedProfile { log.notice("displays changed; profile \(forced, privacy: .public) no longer forced") }
            forcedProfile = nil
            displayIDs = ids
        }
        let setup = config.setup(for: displays, profile: forcedProfile, keeping: controller.profile)
        controller.apply(setup, names: setup.workspaces.isEmpty ? Self.defaultWorkspaces : setup.workspaces,
                         barDisplays: ConfigFile.barDisplays(displays), resync: resync)
    }

    /// Displays came or went, moved, or changed their visible areas. A burst gets one
    /// response 0.5 s after the last notification. While the session is locked or the
    /// displays sleep, the resync after the unlock or wake reads them instead: a sleeping
    /// Mac can report its displays gone (DESIGN.md, section 5.13).
    private func screenParametersChanged() {
        displayChanges += 1
        let number = displayChanges
        log.notice("screen parameters changed (\(number)): \(NSScreen.screens.count) displays")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, number == self.displayChanges, !self.inventory.sessionLocked, !self.screensAsleep else { return }
                self.applyDisplays()
            }
        }
    }

    /// Applies the config file. With errors the running config stays; at launch there is
    /// none, so the last good file or the defaults apply. Returns whether the file applied,
    /// and every problem and warning for the CLI.
    private func reloadConfig(atLaunch: Bool) -> (applied: Bool, messages: [String]) {
        let loaded = ConfigFile.load(atLaunch: atLaunch)
        // A reload without a file changes nothing; saying the defaults apply would be false.
        if !atLaunch, !FileManager.default.fileExists(atPath: ConfigFile.url.path) {
            return (false, ["no config at \(ConfigFile.url.path); the running config is kept"])
        }
        for error in loaded.errors { log.error("config: \(error, privacy: .public)") }
        for warning in loaded.warnings { log.notice("config: \(warning, privacy: .public)") }
        guard let config = loaded.config, let controller else {
            let running = atLaunch ? "the defaults are running" : "the previous config is still running"
            configProblems = loaded.errors.isEmpty ? [] : ["Config has errors; \(running)"] + loaded.errors
            updateProblems()
            return (loaded.errors.isEmpty, loaded.errors + loaded.warnings)
        }
        configProblems = loaded.errors.isEmpty ? [] : ["Config has errors; \(loaded.source) is running"] + loaded.errors
        self.config = config
        forcedProfile = nil
        applyDisplays(resync: !atLaunch)
        controller.mouseFollowsFocus = config.mouseFollowsFocus
        var messages = loaded.errors + loaded.warnings
        let hotkeys = self.hotkeys ?? Hotkeys(layoutProblems: { [weak self] in self?.showHotkeyProblems($0) }) { [weak self] binding in
            _ = self?.respond(to: binding.arguments, received: .now)
        }
        self.hotkeys = hotkeys
        let problems = hotkeys.load(config.modes)
        showHotkeyProblems(problems)
        messages += problems.map(\.description)
        log.notice("config loaded from \(loaded.source, privacy: .public): profile \(controller.profile ?? "base", privacy: .public)")
        return (loaded.errors.isEmpty, messages)
    }

    /// Hotkeys that could not be registered after a load or a layout change.
    private func showHotkeyProblems(_ problems: [Hotkeys.Problem]) {
        for problem in problems { log.error("hotkey: \(problem.description, privacy: .public)") }
        hotkeyProblems = problems.map { "Hotkey \($0.description)" }
        updateProblems()
    }

    private func updateProblems() {
        statusItem?.problems = configProblems + hotkeyProblems + [hidingProblem, focusProblem].compactMap { $0 }
    }

    /// Reads Secure Input after WindowServer reports a change, and once at launch. Nothing
    /// polls, so this never runs inside a switch, though an app that holds Secure Input only
    /// while active makes it run right after one (DESIGN.md, section 5.6).
    ///
    /// Ceiling: a second holder's enable, or a release while another holder remains, sends no
    /// event, so the named holder can be stale until Secure Input turns off and on. Reading
    /// the holder again when the status menu opens would keep the menu current.
    private func secureInputChanged() {
        let current = SecureInput.current()
        guard current != secureInput else { return }
        secureInput = current
        log.notice("secure input \(current.map { "on, held by \($0)" } ?? "off", privacy: .public)")
        statusItem?.secureInput = current
    }

    /// SIGTERM and SIGINT quit through AppKit, so recovery runs in process.
    private func handleTerminationSignals() {
        for signalNumber in [SIGTERM, SIGINT] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }
    }

    /// Locked: windows wait and nothing on screen changes. Unlocked, or awake while unlocked:
    /// the inventory sweeps and the Controller resyncs (DESIGN.md, section 5.1).
    private func lockChanged(_ locked: Bool) {
        inventory.sessionLocked = locked
        guard !locked else { return }
        inventory.sweep()
        applyDisplays()
    }

    private func accessibilityGranted() {
        onboarding = nil
        statusItem?.accessibilityMissing = false
        start()
    }

    private func start() {
        guard let record else { return }
        // Two tiling window managers would fight over every window.
        let otherManager = !NSRunningApplication.runningApplications(withBundleIdentifier: "bobko.aerospace").isEmpty
        let managing = !otherManager || ProcessInfo.processInfo.environment["KOSMOS_MANAGE"] == "1"
        config = ConfigFile.load(atLaunch: true).config ?? Config()
        // NSScreen can list no display in the middle of a change; the main display stands in.
        let main = CGMainDisplayID()
        var displays = ConfigFile.displays()
        if displays.isEmpty { displays = [Display(id: main, name: "Display", frame: CGDisplayBounds(main))] }
        displayIDs = Set(displays.map(\.id))
        let setup = config.setup(for: displays)
        let hiding = Hiding(record: record, guardian: guardian)
        hiding.onProblem = { [weak self] problem in
            self?.hidingProblem = problem
            self?.updateProblems()
        }
        self.hiding = hiding
        let controller = Controller(inventory: inventory, hiding: hiding,
                                    names: setup.workspaces.isEmpty ? Self.defaultWorkspaces : setup.workspaces, setup: setup,
                                    barDisplays: ConfigFile.barDisplays(displays), managing: managing)
        controller.publish = { [weak self] snapshot in self?.server?.publish(Array(snapshot)) }
        controller.onFocusProblem = { [weak self] problem in
            self?.focusProblem = problem
            self?.updateProblems()
        }
        focusProblem = controller.focusProblem
        updateProblems()
        self.controller = controller
        // Hotkeys only when Kosmos manages windows; while observing they would shadow the
        // other window manager's.
        self.managing = managing
        if managing { _ = reloadConfig(atLaunch: true) }
        inventory.startAccessibility()
        let center = NSWorkspace.shared.notificationCenter
        for (name, asleep) in [(NSWorkspace.screensDidSleepNotification, true), (NSWorkspace.screensDidWakeNotification, false)] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.screensAsleep = asleep }
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenParametersChanged() }
        }
        log.notice("started, \(managing ? "managing windows" : "observing only: AeroSpace is running", privacy: .public)")
    }
}
