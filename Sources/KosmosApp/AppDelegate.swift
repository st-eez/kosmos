import AppKit
import os

let log = Logger(subsystem: "io.github.st-eez.kosmos", category: "app")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var instanceLock: InstanceLock?
    private var statusItem: StatusItem?
    private var onboarding: Onboarding?
    private let inventory = Inventory()

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            instanceLock = try InstanceLock(directory: AppPaths.support)
        } catch {
            log.error("\(error.localizedDescription, privacy: .public)")
            exit(1)
        }
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

    private func accessibilityGranted() {
        onboarding = nil
        statusItem?.state = .running
        start()
    }

    private func start() {
        inventory.startAccessibility()
        log.info("started")
    }
}
