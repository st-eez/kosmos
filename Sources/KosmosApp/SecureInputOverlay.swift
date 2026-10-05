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
/// MIT) in AppKit, at its size: a lock over a blurred glow, masked to the edges, that turns
/// once every 2 s and pulses. Core Animation runs both in WindowServer, where Ghostty's SwiftUI
/// animation ticks on the main thread, which Kosmos keeps for switches.
private final class BadgeView: NSView {
    static let size: CGFloat = 35
    /// From the tiling area's top edge, as Ghostty's sits from its window's corner.
    static let inset: CGFloat = 10

    private let glow = CALayer()
    private let spin = CAGradientLayer()
    private let lock = NSImageView()

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.size, height: Self.size))
        wantsLayer = true
        layerUsesCoreImageFilters = true
        let layer = self.layer!
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
        layer.borderWidth = 1

        spin.type = .conic
        spin.colors = [NSColor.systemPurple, .systemBlue, .systemPurple, .systemBlue, .systemPurple].map(\.cgColor)
        spin.startPoint = CGPoint(x: 0.5, y: 0.5)
        spin.endPoint = CGPoint(x: 0.5, y: 0)
        // Larger than the badge, so its corners stay covered as it turns.
        spin.frame = bounds.insetBy(dx: -Self.size / 2, dy: -Self.size / 2)
        spin.filters = [CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: 4])!]
        let edges = CAGradientLayer()
        edges.type = .radial
        edges.colors = [NSColor.clear.cgColor, NSColor.black.cgColor]
        edges.startPoint = CGPoint(x: 0.5, y: 0.5)
        // Clear at the center, full 25 pt from it, as Ghostty's mask.
        edges.endPoint = CGPoint(x: 0.5 + 25 / Self.size, y: 0.5 + 25 / Self.size)
        edges.frame = bounds
        glow.frame = bounds
        glow.mask = edges
        glow.addSublayer(spin)
        layer.addSublayer(glow)

        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = 0
        turn.toValue = -2 * Double.pi
        turn.duration = 2
        turn.repeatCount = .infinity
        spin.add(turn, forKey: "turn")
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 0.5
        pulse.toValue = 1
        pulse.duration = 2
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        glow.add(pulse, forKey: "pulse")

        lock.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "Secure Input")
        lock.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .medium)
        lock.contentTintColor = .labelColor
        lock.imageScaling = .scaleNone
        lock.frame = bounds
        addSubview(lock)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    /// Layer colors are fixed values, resolved under the window's dark appearance.
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            layer?.borderColor = NSColor.systemGray.cgColor
        }
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
        // The same badge in light and dark mode.
        appearance = NSAppearance(named: .darkAqua)
        contentView = BadgeView()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: Preview

extension SecureInputOverlay {
    /// Shows the badge for `seconds` at the top center of the main display, without taking
    /// focus or the mouse, and prints its window number for `screencapture -l`. The glow's blur
    /// and mask need WindowServer, which an offscreen render leaves out.
    static func preview(_ arguments: [String]) -> Int32 {
        guard arguments.count <= 1, let seconds = Double(arguments.first ?? "10") else {
            FileHandle.standardError.write(Data("usage: Kosmos secure-input-preview [seconds]\n".utf8))
            return 2
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let window = BadgeWindow()
        let area = NSScreen.main?.visibleFrame ?? .zero
        window.setFrameOrigin(NSPoint(x: (area.midX - BadgeView.size / 2).rounded(),
                                      y: area.maxY - BadgeView.inset - BadgeView.size))
        window.orderFrontRegardless()
        print(window.windowNumber)
        fflush(stdout)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
        return 0
    }
}
