import AppKit
import CKosmos
import KosmosCore
import KosmosSkyLight
import os

private let bordersLog = Logger(subsystem: "io.github.st-eez.kosmos", category: "borders")

/// Kosmos's own border windows (docs/borders.md). Each window the Session borders gets one
/// transparent window that ignores the mouse, ordered directly above it, so a window that
/// covers it covers its border too; the window's layer draws the ring. A border hidden goes
/// to a pool, and the next window bordered reuses it. Nothing polls: the Controller shows
/// the borders again after each change of the model, of a window's frame or order, and of a
/// slide.
@MainActor
final class Borders {
    /// A border to show: its ring and color, the target's window level, and the alpha a
    /// slide shows the target at.
    struct Shown: Equatable {
        var border: Border
        var level: Int32
        var alpha: Double
        /// The target slides: its border window covers its display, and each display frame
        /// moves only the ring's layer, which takes a fourth of the main thread's time that
        /// moving the window does (kosmos-probe borders-cpu).
        var sliding: Bool
    }

    private var windows: [WindowID: BorderWindow] = [:]
    private var spare: [BorderWindow] = []
    /// Space reads and moves, off the main thread: a read can wait out a Space transition.
    private let spaces = DispatchQueue(label: "kosmos.borders", qos: .userInitiated)
    /// The macOS accent color, the focused window's border unless the config gives one,
    /// as the current appearance shows it.
    private(set) var accent = Borders.readAccent()
    /// Called when the user changes the accent color or the appearance.
    var onAccentChange: (@MainActor () -> Void)?
    private var appearance: NSKeyValueObservation?

    init() {
        // AppKit posts this when the accent or highlight color changes in System Settings.
        NotificationCenter.default.addObserver(forName: NSColor.systemColorsDidChangeNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.readAccentAgain() }
        }
        // Light and dark show the accent in shades of their own.
        appearance = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.readAccentAgain() } }
        }
    }

    private func readAccentAgain() {
        let next = Self.readAccent()
        guard next != accent else { return }
        accent = next
        onAccentChange?()
    }

    /// NSColor.controlAccentColor in sRGB under the app's appearance, else the system blue.
    private static func readAccent() -> BorderColor {
        var accent = BorderColor(red: 0, green: 122 / 255, blue: 1, alpha: 1)
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
            guard let color = NSColor.controlAccentColor.usingColorSpace(.sRGB) else { return }
            accent = BorderColor(red: color.redComponent, green: color.greenComponent, blue: color.blueComponent,
                                 alpha: color.alphaComponent)
        }
        return accent
    }

    /// Shows exactly these borders, by target window, and hides every other one. A border
    /// that is the same as shown costs nothing.
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

    /// Orders the target's border directly above it again: WindowServer reordered the target,
    /// as when its app raises it, which leaves the border below it (kosmos-probe borders).
    func raise(_ target: WindowID) {
        windows[target]?.order(.above, relativeTo: Int(target))
    }

    /// Puts the border in its target's ordinary Space. A new window joins the current Space
    /// of its display, a window moved onto another display joins that display's current
    /// Space, and a window keeps its Space while ordered out (kosmos-probe borders). The
    /// current Space can be another app's native fullscreen Space, so a border shown for
    /// another window, or moved to another display, goes to its target's ordinary Space when
    /// it is in none of them. The target's list can also name the holding Space, or a slide's
    /// animation Space, whose transform would draw the border too, so neither counts.
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

/// One border window: borderless, clear, ignoring the mouse so clicks reach the window under
/// it, never key, out of the window cycle and hidden in Mission Control, as the empty
/// workspace's window is, and kept on screen when another app's Hide Others hides Kosmos.
/// The ring is a layer's border, drawn by Core Animation.
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

    /// Draws `next`, and returns whether its display changed, as it does at the first show.
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
