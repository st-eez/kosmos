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
    private var configProblems: [String] = []
    private var hotkeyProblems: [String] = []
    private var hidingProblem: String?
    private var focusProblem: String?
    private var hiding: Hiding?
    private var secureInput: SecureInput?
    private var config = Config.defaults
    private var forcedProfile: String?
    private var displayIDs: Set<DisplayID> = []
    private var displayChange: DispatchWorkItem?
    private var screensAsleep = false
    /// When `kosmos handover` asked the next quit to leave the record to the Kosmos that
    /// follows.
    private var handoverArmed: ContinuousClock.Instant?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // First, so a SIGTERM during startup quits with exit 0 once startup is done. Killed by
        // the signal, Kosmos would count as crashed, and launch at login would restart it.
        handleTerminationSignals()
        let trusted = AXIsProcessTrusted()
        do {
            // The lock keeps a second Kosmos out and serializes recovery with the guardian, which
            // holds it while it recovers, after the grace it gives the next Kosmos.
            var acquired = try FileLock(KosmosFiles.lock)
            for _ in 0..<60 where acquired == nil {
                usleep(50_000)
                acquired = try FileLock(KosmosFiles.lock)
            }
            guard let lock = acquired else {
                // launchd restarts the agent after exit 1, which suits a lock the guardian still
                // holds, and leaves it stopped after exit 0 (docs/onboarding.md). The guardian has
                // no bundle identifier, so it never counts as another Kosmos.
                let running = NSRunningApplication.runningApplications(withBundleIdentifier: "io.github.st-eez.kosmos")
                    .contains { $0 != NSRunningApplication.current }
                log.error("\(running ? "another Kosmos is running" : "the instance lock is still held", privacy: .public)")
                exit(running ? 0 : 1)
            }
            instanceLock = lock
            let record = try RecordFile(url: KosmosFiles.record)
            self.record = record
            // Windows a previous run left concealed come back before anything else, unless this
            // Kosmos manages windows at once and takes them over in start(adopting:).
            if !trusted { recoverAtStartup(record) }
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
        if trusted {
            start(adopting: true)
        } else {
            statusItem.accessibilityMissing = true
            showSetup(Onboarding.State(accessibility: false), takingKey: true)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Only the quit the arm was for, and only with a guardian to restore the windows should
        // no Kosmos follow (docs/hiding.md).
        let handingOver = handoverArmed.map { .now - $0 < Self.armLife } == true && guardian.isReady
        server?.stop()
        // The last second of changes has no write yet.
        controller?.writeLayout(wait: true)
        // Slides end first, so recovery finds the pool's Spaces empty.
        controller?.endSlides("at quit")
        if handingOver, let hiding {
            hiding.handOver()
            log.notice("quit: the record is left to the Kosmos that starts next")
            return
        }
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
                self?.respond(to: arguments, received: .now, from: .cli) ?? Response(exitCode: 1, stderr: "kosmos: shutting down")
            }
        } catch {
            log.error("socket not started: \(String(describing: error), privacy: .public)")
        }
    }

    private func respond(to arguments: [String], received: ContinuousClock.Instant, from source: CommandSource) -> Response {
        if let query = Query(arguments) { return answer(query) }
        if arguments.first == "handover" { return armHandover(Array(arguments.dropFirst())) }
        switch Command.parse(arguments) {
        case .success(let command): return run(command, received: received, from: source)
        case .failure(let error): return failure(error.message)
        }
    }

    private static let waiting = Response(exitCode: 1, stderr: "kosmos: waiting for Accessibility permission")

    private func failure(_ message: String) -> Response {
        Response(exitCode: 1, stderr: "kosmos: " + message)
    }

    private func answer(_ query: Query) -> Response {
        switch (query, controller) {
        case (.ping, _): Response(stdout: "pong")
        case (.version, _): Response(stdout: kosmosVersion)
        case (.listBindings, _): listBindings()
        case (_, nil): Self.waiting
        case (.state, let controller?): Response(stdout: String(decoding: controller.stateJSON(), as: UTF8.self))
        case (.listWorkspaces, let controller?): Response(stdout: controller.session.workspaceList)
        case (.listWindows, let controller?): Response(stdout: controller.session.windowList(app: controller.appName))
        }
    }

    private func run(_ command: Command, received: ContinuousClock.Instant, from source: CommandSource) -> Response {
        if case .mode(let name) = command { return switchMode(to: name) }
        guard let controller else { return Self.waiting }
        // Changing the model without moving windows would leave the two apart.
        guard controller.managing else { return failure("observing only while another window manager runs") }
        switch command {
        case .reloadConfig:
            controller.turnOnPrivateFocus()
            let (applied, messages) = reloadConfig(ConfigFile.load(atLaunch: false), atLaunch: false)
            return Response(exitCode: applied ? 0 : 1, stderr: messages.joined(separator: "\n"))
        case .profile(let name):
            return applyProfile(name)
        default:
            return controller.run(command, received: received, from: source).map(failure) ?? Response()
        }
    }

    /// `kosmos handover [record version]`, for script/install.sh: a quit within `armLife` leaves
    /// the record to a Kosmos that starts right after it, which reads that version, this build's
    /// when none is given. A refusal disarms (docs/hiding.md).
    private func armHandover(_ arguments: [String]) -> Response {
        handoverArmed = nil
        let version = arguments.isEmpty ? RecoveryRecord.version : arguments.count == 1 ? UInt32(arguments[0]) : nil
        guard let version else { return failure("usage: handover [record version]") }
        guard version == RecoveryRecord.version else {
            return failure("the next Kosmos reads record version \(version) and this one writes \(RecoveryRecord.version), so quitting restores the hidden windows")
        }
        guard hiding != nil else { return failure("no windows are hidden before Kosmos manages them") }
        handoverArmed = .now
        log.notice("handover: a quit within \(Self.armLife, privacy: .public) leaves the record to the Kosmos that follows")
        return Response()
    }

    /// script/install.sh sends its SIGTERM right after the arm.
    private static let armLife: Duration = .seconds(5)

    private func listBindings() -> Response {
        guard let hotkeys else { return failure("no hotkeys are registered") }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let listed = (try? encoder.encode(ListedBinding.list(hotkeys.modes))) ?? Data("[]".utf8)
        return Response(stdout: String(decoding: listed, as: UTF8.self))
    }

    private func switchMode(to name: String) -> Response {
        guard let hotkeys else { return failure("no hotkeys are registered") }
        // The command reports its own problems; the status item keeps the ones a load found,
        // so its icon never changes during a command.
        let problems = hotkeys.switchMode(to: name)
        for problem in problems { log.error("hotkey: \(problem.description, privacy: .public)") }
        return problems.isEmpty ? Response() : Response(exitCode: 1, stderr: problems.map(\.description).joined(separator: "\n"))
    }

    /// The profile holds until the displays change or the config reloads (docs/displays.md).
    private func applyProfile(_ name: String) -> Response {
        guard config.profiles.contains(where: { $0.name == name }) else { return failure("no profile named '\(name)'") }
        forcedProfile = name
        applyDisplays()
        return Response()
    }

    private func applyDisplays() {
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
        controller.apply(setup, barDisplays: ConfigFile.barDisplays(displays))
    }

    /// While the session is locked or the displays sleep, the resync after the unlock or wake
    /// reads the displays instead, as a sleeping Mac can report them gone (docs/displays.md).
    private func screenParametersChanged() {
        log.notice("screen parameters changed: \(NSScreen.screens.count) displays")
        // A gone display's link stops firing, so its slides would hold their windows displaced
        // until the change applies (docs/geometry.md).
        controller?.endSlides("at a display change")
        displayChange?.cancel()
        let apply = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.displayChange = nil
                if !self.inventory.sessionLocked, !self.screensAsleep { self.applyDisplays() }
            }
        }
        displayChange = apply
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: apply)
    }

    private func reloadConfig(_ loaded: ConfigFile.Loaded, atLaunch: Bool) -> (applied: Bool, messages: [String]) {
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
        // At launch the Controller starts with this setup, and a resync would key the empty
        // workspace window for a session the inventory has not filled yet.
        if !atLaunch { applyDisplays() }
        controller.mouseFollowsFocus = config.mouseFollowsFocus
        controller.focusFollowsMouse = config.focusFollowsMouse
        controller.mouseModifier = config.mouseModifier
        controller.animations = config.animations
        controller.borders = config.borders
        var messages = loaded.errors + loaded.warnings
        let hotkeys = self.hotkeys ?? Hotkeys(layoutProblems: { [weak self] in self?.showHotkeyProblems($0) }) { [weak self] binding in
            self?.controller?.endDrag()
            _ = self?.run(binding.command, received: .now, from: .hotkey)
        }
        self.hotkeys = hotkeys
        let problems = hotkeys.load(config.modes)
        showHotkeyProblems(problems)
        messages += problems.map(\.description)
        log.notice("config loaded from \(loaded.source, privacy: .public): profile \(controller.profile ?? "base", privacy: .public)")
        return (loaded.errors.isEmpty, messages)
    }

    private func showHotkeyProblems(_ problems: [Hotkeys.Problem]) {
        for problem in problems { log.error("hotkey: \(problem.description, privacy: .public)") }
        hotkeyProblems = problems.map { "Hotkey \($0.description)" }
        updateProblems()
    }

    private func updateProblems() {
        let missing = SkyLight.missingBridgedOperation.map { "This macOS lacks \($0), so Kosmos hides no windows" }
        statusItem?.problems = configProblems + hotkeyProblems + [missing, hidingProblem, focusProblem].compactMap { $0 }
    }

    /// Ceiling: a second holder's enable, or a release while another holder remains, sends no
    /// event, so the named holder can be stale (docs/hotkeys.md). Reading the holder again when
    /// the status menu opens would keep the menu current.
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

    private func lockChanged(_ locked: Bool) {
        inventory.sessionLocked = locked
        guard !locked else {
            controller?.forgetPresses()
            return
        }
        inventory.sweep()
        applyDisplays()
    }

    private func showSetup(_ state: Onboarding.State, takingKey: Bool) {
        if onboarding == nil {
            onboarding = Onboarding(state, check: { [weak self] in self?.checkPermissions() ?? state },
                                    closedWithKey: { [weak self] in self?.setupClosed(fromAnotherApp: $0) },
                                    finished: { [weak self] in self?.onboarding = nil })
        }
        onboarding?.show(takingKey: takingKey)
    }

    private func checkPermissions() -> Onboarding.State {
        let trusted = AXIsProcessTrusted()
        if trusted, controller == nil {
            statusItem?.accessibilityMissing = false
            start(adopting: false)
        }
        guard let controller, controller.wantsPointer else { return Onboarding.State(accessibility: trusted) }
        controller.renewPointerTapAfterGrant()
        return Onboarding.State(accessibility: trusted, inputMonitoring: CGPreflightListenEventAccess())
    }

    /// Deactivated, Kosmos leaves macOS to activate the app that had the key (docs/onboarding.md).
    private func setupClosed(fromAnotherApp: Bool) {
        if let controller, controller.managing, controller.hasFocusedWindow || !fromAnotherApp {
            controller.refocus()
        } else {
            NSApp.deactivate()
        }
    }

    /// Restores the windows the last Kosmos left concealed, then names this Kosmos in the lock
    /// file, so that Kosmos's guardian leaves (docs/hiding.md).
    private func recoverAtStartup(_ record: RecordFile) {
        log.notice("startup recovery: \(String(describing: Recovery.run(file: record)), privacy: .public)")
        instanceLock?.name(.current)
    }

    /// `adopting` at the launch: the startup recovery has not run.
    private func start(adopting: Bool) {
        guard let record else { return }
        // Two tiling window managers would fight over every window.
        let otherManager = !NSRunningApplication.runningApplications(withBundleIdentifier: "bobko.aerospace").isEmpty
        let managing = !otherManager || ProcessInfo.processInfo.environment["KOSMOS_MANAGE"] == "1"
        let loaded = ConfigFile.load(atLaunch: true)
        config = loaded.config ?? .defaults
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
        let controller = Controller(inventory: inventory, hiding: hiding, setup: setup,
                                    barDisplays: ConfigFile.barDisplays(displays), managing: managing)
        controller.publish = { [weak self] snapshot in self?.server?.publish(Array(snapshot)) }
        controller.onFocusProblem = { [weak self] problem in
            self?.focusProblem = problem
            self?.updateProblems()
        }
        controller.onInputMonitoringMissing = { [weak self] in
            self?.showSetup(Onboarding.State(accessibility: true, inputMonitoring: false), takingKey: false)
        }
        focusProblem = controller.focusProblem
        updateProblems()
        self.controller = controller
        if adopting {
            // Named in the lock file, this Kosmos has the last one's guardian leave, so it takes
            // the record over only with a guardian of its own ready (docs/hiding.md).
            if managing, guardian.awaitReady(.seconds(1)) {
                instanceLock?.name(.current)
                controller.adopt()
            } else {
                recoverAtStartup(record)
            }
        }
        // Hotkeys only when Kosmos manages windows; while observing they would shadow the
        // other window manager's.
        if managing { _ = reloadConfig(loaded, atLaunch: true) }
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
