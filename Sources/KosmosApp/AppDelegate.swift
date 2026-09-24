import AppKit
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

    private func respond(to arguments: [String], received: ContinuousClock.Instant) -> Response {
        switch arguments {
        case ["ping"]: return Response(stdout: "pong")
        case ["version"]: return Response(stdout: kosmosVersion)
        default:
            guard let controller else {
                return Response(exitCode: 1, stderr: "kosmos: waiting for Accessibility permission")
            }
            let result = controller.run(arguments, received: received)
            return result.code == 0 ? Response(stdout: result.text) : Response(exitCode: result.code, stderr: "kosmos: " + result.text)
        }
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
        let controller = Controller(inventory: inventory, hiding: Hiding(record: record, guardian: guardian),
                                    names: (1...9).map(String.init), managing: managing)
        controller.publish = { [weak self] snapshot in self?.server?.publish(Array(snapshot)) }
        self.controller = controller
        inventory.startAccessibility()
        log.notice("started, \(managing ? "managing windows" : "observing only: AeroSpace is running", privacy: .public)")
    }
}
