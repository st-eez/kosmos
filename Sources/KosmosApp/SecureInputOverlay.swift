import AppKit
import KosmosCore

/// A lock badge on screen while Secure Input holds, for a Mac whose hidden menu bar hides the
/// status item's lock. Only a Secure Input change and its own wait write to it, never a switch
/// (docs/hotkeys.md).
@MainActor
final class SecureInputOverlay {
    /// Nil while Kosmos registers no hotkeys, as none then waits.
    var focusedMonitor: @MainActor () -> Monitor? = { nil }
    private var hold = SecureInputHold()
    private var wait: DispatchWorkItem?
    private lazy var window = BadgeWindow()

    func update(on: Bool) {
        hold.update(on: on, at: .now)
        refresh()
    }

    private func refresh() {
        wait?.cancel()
        wait = nil
        let now = ContinuousClock.now
        if hold.shows(at: now), let monitor = focusedMonitor() {
            return show(on: monitor)
        }
        window.orderOut(nil)
        // Dispatch's clock and the continuous clock can part by rounding, so a wait that fires
        // short of the delay waits again.
        guard let due = hold.due, due > now else { return }
        let next = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
        wait = next
        DispatchQueue.main.asyncAfter(deadline: .now() + (due - now).milliseconds / 1000, execute: next)
    }

    /// At the top center of the tiling area, clear of a terminal's own badge in its window's
    /// corner and of a centered password dialog.
    private func show(on monitor: Monitor) {
        guard !window.isVisible else { return }
        let area = NSScreen.flipped(monitor.tilingArea)
        let size = BadgeView.size
        window.setFrameOrigin(NSPoint(x: (area.midX - size / 2).rounded(), y: area.maxY - BadgeView.inset - size))
        window.orderFrontRegardless()
        log.notice("secure input badge shown on display \(monitor.id)")
    }
}

/// Ghostty's Secure Input badge (macos/Sources/Features/Secure Input/SecureInputOverlay.swift,
/// MIT) in AppKit: a lock over a glow at the edges that turns once every 2 s and pulses, at
/// Ghostty's size. Plain layers, which the snapshot's offscreen render draws as the screen does.
private final class BadgeView: NSView {
    static let size: CGFloat = 35
    /// From the tiling area's top edge, as Ghostty's sits from its window's corner.
    static let inset: CGFloat = 10

    private let glow = CAGradientLayer()
    /// The background color fading out toward the edges, so the glow shows only there.
    private let fade = CAGradientLayer()
    private let lock = CALayer()

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.size, height: Self.size))
        wantsLayer = true
        let layer = self.layer!
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
        layer.borderWidth = 1

        glow.type = .conic
        glow.colors = [NSColor.cyan, .systemPurple, .orange, .systemPurple, .cyan].map(\.cgColor)
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 0.5, y: 0)
        // Larger than the badge, so its corners stay covered as it turns.
        glow.frame = bounds.insetBy(dx: -Self.size / 2, dy: -Self.size / 2)
        fade.type = .radial
        fade.startPoint = CGPoint(x: 0.5, y: 0.5)
        // Gone 25 pt from the center, where Ghostty's mask is full.
        fade.endPoint = CGPoint(x: 0.5 + 25 / Self.size, y: 0.5 + 25 / Self.size)
        fade.frame = bounds
        lock.frame = bounds
        lock.contentsGravity = .center
        for sublayer in [glow, fade, lock] { layer.addSublayer(sublayer) }

        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = 0
        turn.toValue = -2 * Double.pi
        turn.duration = 2
        turn.repeatCount = .infinity
        glow.add(turn, forKey: "turn")
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 0.5
        pulse.toValue = 1
        pulse.duration = 2
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        glow.add(pulse, forKey: "pulse")
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    /// Layer colors are fixed values, so each appearance or scale change sets them again.
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let background = NSColor.windowBackgroundColor
            layer?.backgroundColor = background.cgColor
            layer?.borderColor = NSColor.systemGray.cgColor
            fade.colors = [background.cgColor, background.withAlphaComponent(0).cgColor]
            let scale = window?.backingScaleFactor ?? 4
            let symbol = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "Secure Input")!
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor.labelColor.usingColorSpace(.sRGB)!])))!
            lock.contentsScale = scale
            lock.contents = symbol.layerContents(forContentsScale: scale)
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }
}

/// Kept out of management as the border windows are: Kosmos is an accessory app, whose
/// windows the inventory never admits (docs/inventory.md), and its level is not 0.
private final class BadgeWindow: NSWindow {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: BadgeView.size, height: BadgeView.size),
                   styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        animationBehavior = .none
        isReleasedWhenClosed = false
        canHide = false
        // Above floating windows, modal panels and the menu bar when it shows.
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        contentView = BadgeView()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: Snapshot

extension SecureInputOverlay {
    /// Draws the badge in light and dark mode at 4x without showing a window, still: the turn
    /// and the pulse need WindowServer.
    static func snapshot(_ arguments: [String]) -> Int32 {
        guard arguments.count == 1 else {
            FileHandle.standardError.write(Data("usage: Kosmos secure-input-snapshot <directory>\n".utf8))
            return 2
        }
        let directory = URL(filePath: arguments[0], directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (appearance, mode) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                let view = BadgeView()
                view.appearance = NSAppearance(named: appearance)
                view.updateLayer()
                view.layoutSubtreeIfNeeded()
                let scale: CGFloat = 4
                let pixels = Int(BadgeView.size * scale)
                guard let bitmap = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                    bytesPerRow: 0, bitsPerPixel: 0),
                    let context = NSGraphicsContext(bitmapImageRep: bitmap)?.cgContext else { return 1 }
                context.scaleBy(x: scale, y: scale)
                view.layer!.render(in: context)
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
