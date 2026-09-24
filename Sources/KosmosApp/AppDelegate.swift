import AppKit
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
        if let record { log.notice("quit recovery: \(String(describing: Recovery.run(file: record)), privacy: .public)") }
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
        controller = Controller(inventory: inventory, hiding: Hiding(record: record, guardian: guardian),
                                names: (1...9).map(String.init), managing: managing)
        inventory.startAccessibility()
        log.notice("started, \(managing ? "managing windows" : "observing only: AeroSpace is running", privacy: .public)")
    }
}
