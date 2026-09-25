import AppKit
import KosmosIPC
import ServiceManagement

/// Its image changes with Kosmos's state and never during a command: a status item that
/// changes width makes the menu bar lay itself out again (docs/overview.md, section 2).
@MainActor
final class StatusItem: NSObject, NSMenuDelegate {
    var accessibilityMissing = false { didSet { updateImage() } }
    var problems: [String] = [] { didSet { updateImage() } }
    var secureInput: SecureInput? { didSet { updateImage() } }

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var shownImage = ""

    override init() {
        super.init()
        item.behavior = .removalAllowed
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        updateImage()
    }

    /// Secure Input outranks problems, as it explains keys that do nothing right now.
    private func updateImage() {
        let name = accessibilityMissing ? "exclamationmark.triangle"
            : secureInput != nil ? "lock.square"
            : problems.isEmpty ? "mark" : "exclamationmark.octagon"
        guard name != shownImage else { return }
        shownImage = name
        let image = name == "mark" ? Self.mark : NSImage(systemSymbolName: name, accessibilityDescription: "Kosmos")
        image?.isTemplate = true
        item.button?.image = image
    }

    /// The app icon's mark, a disc split by its seam, at the size of the menu bar's SF Symbols,
    /// with the seam on whole pixels at 1x and 2x.
    private static let mark: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let disc = NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: 14, height: 14))
            NSColor.black.setFill()
            for side in [NSRect(x: 0, y: 0, width: 8, height: 18), NSRect(x: 10, y: 0, width: 8, height: 18)] {
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: side).addClip()
                disc.fill()
                NSGraphicsContext.restoreGraphicsState()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Kosmos"
        return image
    }()

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(withTitle: "Kosmos \(kosmosVersion)", action: nil, keyEquivalent: "")
        if accessibilityMissing {
            menu.addItem(withTitle: "Waiting for Accessibility permission", action: nil, keyEquivalent: "")
        }
        if let secureInput {
            menu.addItem(withTitle: "Secure Input is on, held by \(secureInput)", action: nil, keyEquivalent: "")
            menu.addItem(withTitle: "Until it is off, alt and alt-shift bindings on letter, digit and punctuation keys do nothing",
                         action: nil, keyEquivalent: "")
        }
        for problem in problems.prefix(8) { menu.addItem(withTitle: problem, action: nil, keyEquivalent: "") }
        if problems.count > 8 { menu.addItem(withTitle: "and \(problems.count - 8) more in the log", action: nil, keyEquivalent: "") }
        menu.addItem(.separator())
        menu.addItem(launchAtLoginItem())
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Kosmos", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    private func launchAtLoginItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        item.target = self
        switch LaunchAtLogin.service.status {
        case .enabled:
            item.state = .on
            if LaunchAtLogin.isAgent { item.subtitle = "Turning it off quits Kosmos" }
        case .requiresApproval:
            item.state = .mixed
            item.subtitle = "Needs approval in Login Items"
            item.action = #selector(openLoginItems)
        default:
            break
        }
        return item
    }

    @objc private func toggleLaunchAtLogin() {
        let service = LaunchAtLogin.service
        do {
            if service.status == .enabled {
                let agent = LaunchAtLogin.isAgent
                try service.unregister()
                // launchd kills the agent's process. Quitting restores hidden windows in
                // process, and the guardian restores them if the kill comes first.
                if agent { NSApp.terminate(nil) }
            } else {
                try service.register()
            }
        } catch {
            log.error("launch at login: \(error.localizedDescription, privacy: .public)")
        }
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    @objc private func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }
}
