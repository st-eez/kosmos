import AppKit
import KosmosIPC

/// A static menu bar icon. It changes only when Kosmos's state changes, never during a
/// command, because a status item that changes width makes the menu bar lay itself out
/// again (DESIGN.md, section 2). The menu is built when it opens.
@MainActor
final class StatusItem: NSObject, NSMenuDelegate {
    enum State { case running, accessibilityMissing, configError }

    var state = State.running {
        didSet { if state != oldValue { updateImage() } }
    }

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

    override init() {
        super.init()
        item.behavior = .removalAllowed
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        updateImage()
    }

    private func updateImage() {
        let name = switch state {
        case .running: "square.grid.2x2"
        case .accessibilityMissing: "exclamationmark.triangle"
        case .configError: "exclamationmark.octagon"
        }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Kosmos")
        image?.isTemplate = true
        item.button?.image = image
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(withTitle: "Kosmos \(kosmosVersion)", action: nil, keyEquivalent: "")
        if state == .accessibilityMissing {
            menu.addItem(withTitle: "Waiting for Accessibility permission", action: nil, keyEquivalent: "")
        }
        if state == .configError {
            menu.addItem(withTitle: "Config has errors; the previous config is running", action: nil, keyEquivalent: "")
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Kosmos", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }
}
