import AppKit
import CKosmos
import KosmosCore
import KosmosSkyLight
import os

private let bordersLog = Logger(subsystem: "io.github.st-eez.kosmos", category: "borders")

/// Kosmos's own border windows, each ordered directly above its target, so a window that
/// covers the target covers its border too (docs/borders.md).
@MainActor
final class Borders {
    struct Shown: Equatable {
        var border: Border
        var level: Int32
        var alpha: Double
        /// While the target slides, its border window covers its display and each display frame
        /// moves only the ring's layer, a fourth of the cost of moving the window (docs/borders.md).
        var sliding: Bool
    }

    private var windows: [WindowID: BorderWindow] = [:]
    /// A border window keeps to one display: moved to another display's Space before its new
    /// frame lands, it showed there at its old frame (docs/borders.md).
    private var spare: [DisplayID: [BorderWindow]] = [:]
    /// A Space read can wait out a Space transition, so Space reads and moves run here.
    private let spaces = DispatchQueue(label: "kosmos.borders", qos: .userInitiated)
    private(set) var accent = Borders.readAccent()
    private(set) var red = Borders.readRed()
    var onAccentChange: (@MainActor () -> Void)?
    private var appearance: NSKeyValueObservation?

    init() {
        NotificationCenter.default.addObserver(forName: NSColor.systemColorsDidChangeNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.readAccentAgain() }
        }
        // Light and dark show the accent in shades of their own.
        appearance = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            onMain { self?.readAccentAgain() }
        }
    }

    private func readAccentAgain() {
        let next = (Self.readAccent(), Self.readRed())
        guard next != (accent, red) else { return }
        (accent, red) = next
        onAccentChange?()
    }

    private static func readAccent() -> BorderColor {
        read(.controlAccentColor, else: BorderColor(red: 0, green: 122 / 255, blue: 1, alpha: 1))
    }

    private static func readRed() -> BorderColor {
        read(.systemRed, else: BorderColor(red: 1, green: 59 / 255, blue: 48 / 255, alpha: 1))
    }

    private static func read(_ system: NSColor, else fallback: BorderColor) -> BorderColor {
        var read = fallback
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
            guard let color = system.usingColorSpace(.sRGB) else { return }
            read = BorderColor(red: color.redComponent, green: color.greenComponent, blue: color.blueComponent,
                               alpha: color.alphaComponent)
        }
        return read
    }

    func show(_ shown: [WindowID: Shown]) {
        for (target, window) in windows where shown[target]?.border.display != window.display {
            window.orderOut(nil)
            windows[target] = nil
            spare[window.display, default: []].append(window)
        }
        for (target, next) in shown {
            let display = next.border.display
            let window = windows[target], fresh = window == nil
            let border = window ?? spare[display]?.popLast() ?? BorderWindow(display: display)
            windows[target] = border
            // Setting another level can move the border within the stacking order.
            let leveled = border.level.rawValue != Int(next.level)
            border.show(next)
            if fresh || leveled { border.order(.above, relativeTo: Int(target)) }
            if fresh { pin(border, to: target) }
        }
    }

    /// A raise of the target leaves its border below it (kosmos-probe borders).
    func raise(_ target: WindowID) {
        windows[target]?.order(.above, relativeTo: Int(target))
    }

    /// A border joins its display's current Space, maybe another app's fullscreen one, so it
    /// moves to its target's ordinary Space on its own display, or stays (docs/borders.md).
    private func pin(_ window: BorderWindow, to target: WindowID) {
        let border = WindowID(window.windowNumber), display = window.display
        spaces.async {
            let ordinary = Displays.current().ordinarySpaces(on: display)
            let targetSpaces = (SkyLight.spaces(of: target) ?? []).filter(ordinary.contains)
            let borderSpaces = SkyLight.spaces(of: border) ?? []
            guard let space = targetSpaces.first, Set(targetSpaces).isDisjoint(with: borderSpaces) else { return }
            SLSMoveWindowsToManagedSpace(SkyLight.connection, [border] as CFArray, space)
            bordersLog.info("border \(border) of \(target) moved from Spaces \(borderSpaces, privacy: .public) to \(space)")
        }
    }
}

/// `.transient` hides it in Mission Control, and `canHide = false` keeps it on screen when
/// another app's Hide Others hides Kosmos.
private final class BorderWindow: NSWindow {
    let display: DisplayID
    private let ring = CALayer()
    private var shown: Borders.Shown?

    init(display: DisplayID) {
        self.display = display
        super.init(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1), styleMask: [.borderless], backing: .buffered,
                   defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        animationBehavior = .none
        isReleasedWhenClosed = false
        canHide = false
        collectionBehavior = [.transient, .ignoresCycle]
        let view = NSView()
        view.wantsLayer = true
        contentView = view
        view.layer?.addSublayer(ring)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(_ next: Borders.Shown) {
        guard next != shown else { return }
        let previous = shown
        shown = next
        let border = next.border
        let frame = next.sliding ? border.displayFrame : border.frame
        let appKitFrame = NSScreen.flipped(frame)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if self.frame.size != appKitFrame.size {
            setFrame(appKitFrame, display: false)
        } else if self.frame.origin != appKitFrame.origin {
            // A tenth of a resize's cost (kosmos-probe borders).
            setFrameOrigin(appKitFrame.origin)
        }
        if level.rawValue != Int(next.level) { level = NSWindow.Level(rawValue: Int(next.level)) }
        // In the layer's coordinates, from the window's bottom left.
        ring.frame = CGRect(x: border.ring.minX - frame.minX, y: frame.maxY - border.ring.maxY,
                            width: border.ring.width, height: border.ring.height)
        ring.cornerRadius = border.cornerRadius
        ring.borderWidth = border.lineWidth
        if previous?.border.color != border.color {
            let color = border.color
            ring.borderColor = CGColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
        }
        ring.opacity = Float(next.alpha)
        CATransaction.commit()
    }
}
