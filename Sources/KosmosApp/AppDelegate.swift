import AppKit
import KosmosCore
import KosmosIPC
import KosmosRecovery
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
    private var signalSources: [DispatchSourceSignal] = []
    private var controller: Controller?
    private var server: IPCServer?
    private var hotkeys: Hotkeys?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            // The lock keeps a second Kosmos out and serializes recovery with the guardian.
            guard let lock = try FileLock(KosmosFiles.lock) else {
                log.error("another Kosmos is running")
                exit(1)
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
        handleTerminationSignals()
        guardian.start()
        startServer()

        let statusItem = StatusItem()
        self.statusItem = statusItem
        // WindowServer tracking needs no permission, so it starts before the Accessibility grant.
        inventory.start()
        if AXIsProcessTrusted() {
            start()
        } else {
            statusItem.state = .accessibilityMissing
            onboarding = Onboarding { [weak self] in self?.accessibilityGranted() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        server?.stop()
        if let record { log.notice("quit recovery: \(String(describing: Recovery.run(file: record)), privacy: .public)") }
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
            let problems = reloadConfig()
            return problems.isEmpty ? Response() : Response(exitCode: 1, stderr: problems.joined(separator: "\n"))
        default:
            guard let controller else {
                return Response(exitCode: 1, stderr: "kosmos: waiting for Accessibility permission")
            }
            let result = controller.run(arguments, received: received)
            return result.code == 0 ? Response(stdout: result.text) : Response(exitCode: result.code, stderr: "kosmos: " + result.text)
        }
    }

    /// Applies the config file, or keeps the running one when it has errors.
    @discardableResult
    private func reloadConfig() -> [String] {
        let (config, problems) = ConfigFile.load()
        for problem in problems { log.error("config: \(problem, privacy: .public)") }
        guard let config, let controller else {
            statusItem?.state = config == nil && !problems.isEmpty && FileManager.default.fileExists(atPath: ConfigFile.url.path)
                ? .configError : (statusItem?.state ?? .running)
            return problems
        }
        statusItem?.state = .running
        let displays = ConfigFile.displays()
        let setup = config.setup(for: displays)
        controller.reconfigure(gaps: displays.first.map { ConfigFile.gaps(config, on: $0) } ?? Gaps(), rules: setup.rules)
        if setup.workspaces != controller.workspaceNames {
            log.notice("the workspace list changed; it takes effect when Kosmos restarts")
        }
        let hotkeys = self.hotkeys ?? Hotkeys { [weak self] binding in
            _ = self?.respond(to: binding.arguments, received: .now)
        }
        self.hotkeys = hotkeys
        for problem in hotkeys.load(config.modes) { log.error("hotkey: \(problem.description, privacy: .public)") }
        log.notice("config loaded: profile \(setup.profile ?? "base", privacy: .public), \(setup.workspaces.count) workspaces")
        return problems
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

    private func accessibilityGranted() {
        onboarding = nil
        statusItem?.state = .running
        start()
    }

    private func start() {
        guard let record else { return }
        // Two tiling window managers would fight over every window.
        let otherManager = !NSRunningApplication.runningApplications(withBundleIdentifier: "bobko.aerospace").isEmpty
        let managing = !otherManager || ProcessInfo.processInfo.environment["KOSMOS_MANAGE"] == "1"
        // The workspace list is read once; the rest of the config applies on every reload.
        let config = ConfigFile.load().config
        let displays = ConfigFile.displays()
        let names = config.map { $0.setup(for: displays).workspaces } ?? (1...9).map(String.init)
        let gaps = config.flatMap { config in displays.first.map { ConfigFile.gaps(config, on: $0) } } ?? Gaps()
        let controller = Controller(inventory: inventory, hiding: Hiding(record: record, guardian: guardian),
                                    names: names, gaps: gaps, managing: managing)
        controller.publish = { [weak self] snapshot in self?.server?.publish(Array(snapshot)) }
        self.controller = controller
        // Hotkeys only when Kosmos manages windows; while observing they would shadow the
        // other window manager's.
        if managing { reloadConfig() } else { controller.rules = config.map { $0.setup(for: displays).rules } ?? [] }
        inventory.startAccessibility()
        log.notice("started, \(managing ? "managing windows" : "observing only: AeroSpace is running", privacy: .public)")
    }
}
