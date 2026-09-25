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
    private var spare: [BorderWindow] = []
    /// A Space read can wait out a Space transition, so Space reads and moves run here.
    private let spaces = DispatchQueue(label: "kosmos.borders", qos: .userInitiated)
    private(set) var accent = Borders.readAccent()
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
        let next = Self.readAccent()
        guard next != accent else { return }
        accent = next
        onAccentChange?()
    }

    private static func readAccent() -> BorderColor {
        var accent = BorderColor(red: 0, green: 122 / 255, blue: 1, alpha: 1)
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
            guard let color = NSColor.controlAccentColor.usingColorSpace(.sRGB) else { return }
            accent = BorderColor(red: color.redComponent, green: color.greenComponent, blue: color.blueComponent,
                                 alpha: color.alphaComponent)
        }
        return accent
    }

    func show(_ shown: [WindowID: Shown]) {
        for (target, window) in windows where shown[target] == nil {
            window.orderOut(nil)
            windows[target] = nil
            spare.append(window)
        }
        for (target, next) in shown {
            let window = windows[target], fresh = window == nil
            let border = window ?? spare.popLast() ?? BorderWindow()
            windows[target] = border
            // Setting another level can move the border within the stacking order.
            let leveled = border.level.rawValue != Int(next.level)
            let displayChanged = border.show(next)
            if fresh || leveled { border.order(.above, relativeTo: Int(target)) }
            if fresh || displayChanged { pin(border, to: target) }
        }
    }

    /// A raise of the target leaves its border below it (kosmos-probe borders).
    func raise(_ target: WindowID) {
        windows[target]?.order(.above, relativeTo: Int(target))
    }

    /// A border joins its display's current Space, maybe another app's fullscreen one, so it
    /// moves to its target's ordinary Space, never the holding or a slide's (docs/borders.md).
    private func pin(_ window: BorderWindow, to target: WindowID) {
        let border = UInt32(window.windowNumber)
        spaces.async {
            let ordinary = Displays.current().ordinarySpaces
            let targetSpaces = (kosmos_window_spaces(target) as? [UInt64] ?? []).filter(ordinary.contains)
            let borderSpaces = kosmos_window_spaces(border) as? [UInt64] ?? []
            guard let space = targetSpaces.first, Set(targetSpaces).isDisjoint(with: borderSpaces) else { return }
            SLSMoveWindowsToManagedSpace(SkyLight.connection, [border] as CFArray, space)
            bordersLog.info("border \(border) of \(target) moved from Spaces \(borderSpaces, privacy: .public) to \(space)")
        }
    }
}

/// `.transient` hides it in Mission Control, and `canHide = false` keeps it on screen when
/// another app's Hide Others hides Kosmos.
private final class BorderWindow: NSWindow {
    private let ring = CALayer()
    private var shown: Borders.Shown?

    init() {
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

    /// Returns whether the border's display changed, as it does at the first show.
    func show(_ next: Borders.Shown) -> Bool {
        guard next != shown else { return false }
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
        return previous?.border.display != border.display
    }
}
