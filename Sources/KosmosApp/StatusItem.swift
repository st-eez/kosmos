import AppKit
import KosmosIPC

/// A static menu bar icon. It changes only when Kosmos's state changes, never during a
/// command, because a status item that changes width makes the menu bar lay itself out
/// again (DESIGN.md, section 2). The menu is built when it opens.
@MainActor
final class StatusItem: NSObject, NSMenuDelegate {
    var accessibilityMissing = false { didSet { updateImage() } }
    /// Config errors and hotkeys that could not be registered, shown in the menu.
    var problems: [String] = [] { didSet { updateImage() } }

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

    /// Waiting for Accessibility outranks problems, which outrank running normally.
    private func updateImage() {
        let name = accessibilityMissing ? "exclamationmark.triangle"
            : problems.isEmpty ? "square.grid.2x2" : "exclamationmark.octagon"
        guard name != shownImage else { return }
        shownImage = name
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Kosmos")
        image?.isTemplate = true
        item.button?.image = image
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(withTitle: "Kosmos \(kosmosVersion)", action: nil, keyEquivalent: "")
        if accessibilityMissing {
            menu.addItem(withTitle: "Waiting for Accessibility permission", action: nil, keyEquivalent: "")
        }
        for problem in problems.prefix(8) { menu.addItem(withTitle: problem, action: nil, keyEquivalent: "") }
        if problems.count > 8 { menu.addItem(withTitle: "and \(problems.count - 8) more in the log", action: nil, keyEquivalent: "") }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Kosmos", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }
}
