import AppKit
import KosmosCore

/// Secure Input and its holder on screen, for a Mac whose hidden menu bar hides the status
/// item's lock. Only a Secure Input change and its own wait write to it, never a switch
/// (docs/hotkeys.md).
@MainActor
final class SecureInputOverlay {
    /// Nil while Kosmos registers no hotkeys, as none then waits.
    var focusedDisplay: @MainActor () -> DisplayID? = { nil }
    private var hold = SecureInputHold<SecureInput>()
    private var wait: DispatchWorkItem?
    private var window: OverlayWindow?

    func update(_ secureInput: SecureInput?) {
        hold.update(secureInput, at: .now)
        refresh()
    }

    private func refresh() {
        wait?.cancel()
        wait = nil
        let now = ContinuousClock.now
        if let holder = hold.shown(at: now), let display = focusedDisplay(),
           let screen = NSScreen.screens.first(where: { $0.displayID == display }) {
            return show(holder, on: screen)
        }
        window?.orderOut(nil)
        // Dispatch's clock and the continuous clock can part by rounding, so a wait that fires
        // short of the delay waits again.
        guard let due = hold.due, due > now else { return }
        let next = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
        wait = next
        DispatchQueue.main.asyncAfter(deadline: .now() + (due - now).milliseconds / 1000, execute: next)
    }

    /// At the top center, below the notch and a menu bar that stays shown, so it covers no
    /// centered password dialog.
    private func show(_ holder: SecureInput, on screen: NSScreen) {
        let window = self.window ?? OverlayWindow()
        self.window = window
        if !window.isVisible { log.notice("secure input overlay shown on display \(screen.displayID)") }
        window.setContent(Self.content(for: holder))
        let top = min(screen.visibleFrame.maxY, screen.frame.maxY - screen.safeAreaInsets.top)
        window.setFrameOrigin(NSPoint(x: (screen.frame.midX - window.frame.width / 2).rounded(),
                                      y: top - 8 - window.frame.height))
        window.orderFrontRegardless()
    }

    private static func content(for holder: SecureInput) -> NSView {
        let lock = NSImageView(image: NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)!)
        lock.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 17, weight: .medium)
        lock.contentTintColor = .secondaryLabelColor
        let title = NSTextField(labelWithString: holder.heldBy)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let detail = NSTextField(labelWithString: SecureInput.waiting)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        let text = NSStackView(views: [title, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        let row = NSStackView(views: [lock, text])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        // Kosmos is never the active app, and an inactive window's material draws flat.
        background.state = .active
        background.maskImage = rounded(radius: 12)
        background.addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -16),
            row.topAnchor.constraint(equalTo: background.topAnchor, constant: 10),
            row.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -10),
        ])
        return background
    }

    /// A mask on the content view shapes the window and its shadow.
    private static func rounded(radius: CGFloat) -> NSImage {
        let edge = 2 * radius + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { bounds in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

// MARK: Snapshot

extension SecureInputOverlay {
    /// Draws the overlay in light and dark mode without showing a window. The material's blur
    /// of what lies behind needs WindowServer, so the picture shows its flat fallback.
    static func snapshot(_ arguments: [String]) -> Int32 {
        guard arguments.count == 1 else {
            FileHandle.standardError.write(Data("usage: Kosmos secure-input-snapshot <directory>\n".utf8))
            return 2
        }
        let directory = URL(filePath: arguments[0], directoryHint: .isDirectory)
        let holder = SecureInput(pid: 4242, appName: "Ghostty")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (appearance, mode) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                let window = OverlayWindow()
                window.appearance = NSAppearance(named: appearance)
                window.setContent(content(for: holder))
                let view = window.contentView!
                let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let file = directory.appending(path: "secure-input-\(mode).png")
                try bitmap.representation(using: .png, properties: [:])!.write(to: file)
                print(file.path)
            }
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            return 1
        }
        return 0
    }
}

/// Kept out of management as the border windows are: Kosmos is an accessory app, whose
/// windows the inventory never admits (docs/inventory.md), and its level is not 0.
private final class OverlayWindow: NSWindow {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        ignoresMouseEvents = true
        animationBehavior = .none
        isReleasedWhenClosed = false
        canHide = false
        // Above floating windows, modal panels and the menu bar when it shows.
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func setContent(_ view: NSView) {
        contentView = view
        setContentSize(view.fittingSize)
        invalidateShadow()
    }
}
