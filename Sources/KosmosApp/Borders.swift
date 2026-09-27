import AppKit
import CKosmos
import KosmosCore
import KosmosSkyLight
import os

private let bordersLog = Logger(subsystem: "io.github.st-eez.kosmos", category: "borders")

/// Kosmos's own border windows, each ordered directly below its target, so a window that
/// covers the target covers its border too, and the target is topmost over its frame
/// (docs/borders.md).
@MainActor
final class Borders {
    private var pool = BorderPool<BorderWindow>()
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

    /// `fullscreen`: the displays that may show a native fullscreen Space (docs/borders.md).
    func show(_ shown: [WindowID: ShownBorder], fullscreen: Set<DisplayID> = []) {
        for step in pool.show(shown, fullscreen: fullscreen, make: { BorderWindow(display: $0, frame: $1) }) {
            switch step {
            case .putBack(let window):
                let began = CACurrentMediaTime()
                window.putBack()
                bordersLog.debug("""
                    border \(window.windowNumber) put back on display \(window.display) in \
                    \(ms(since: began), format: .fixed(precision: 2)) ms
                    """)
            case .clear(let window):
                window.clear()
            case .ready(let window, let target, let next):
                orderIn(window, next, below: target, ready: true)
            case .orderIn(let window, let target, let next):
                orderIn(window, next, below: target)
            case .show(let window, let target, let next, let taken):
                // Setting another level can move the border within the stacking order.
                let leveled = window.level.rawValue != Int(next.level)
                window.show(next)
                if leveled { window.order(.below, relativeTo: Int(target)) }
                guard taken else { continue }
                pin(window, to: target, thenShow: false)
                bordersLog.debug("ring of \(target) moved to border \(window.windowNumber), ready on display \(window.display)")
            case .wait(let window, let target):
                // Ordered in there before its move, it would draw on the fullscreen app, and a
                // frame set before the move might take it back to the fullscreen Space.
                pin(window, to: target, thenShow: true)
            }
        }
    }

    private func orderIn(_ window: BorderWindow, _ next: ShownBorder, below target: WindowID, ready: Bool = false) {
        let began = CACurrentMediaTime()
        window.show(next)
        let framed = CACurrentMediaTime()
        window.order(.below, relativeTo: Int(target))
        pin(window, to: target, thenShow: false)
        bordersLog.debug("""
            border \(window.windowNumber) of \(target) ordered in on display \(window.display)\
            \(ready ? " ready for the slide" : "", privacy: .public): framed in \
            \((framed - began) * 1000, format: .fixed(precision: 2)) ms, ordered below it in \
            \(ms(since: framed), format: .fixed(precision: 2)) ms
            """)
    }

    /// A raise of the target leaves its border under the windows the raise put the target
    /// over (kosmos-probe borders). A waiting border is ordered below its target when it shows.
    func raise(_ target: WindowID) {
        let windows = pool.ordered(below: target)
        guard !windows.isEmpty else { return }
        let began = CACurrentMediaTime()
        for window in windows { window.order(.below, relativeTo: Int(target)) }
        bordersLog.debug("""
            \(windows.count) border windows of \(target) ordered below it again in \
            \(ms(since: began), format: .fixed(precision: 2)) ms
            """)
    }

    /// A border joins its display's current Space, maybe another app's fullscreen one, so it
    /// moves to its target's ordinary Space on its own display, or stays (docs/borders.md).
    private func pin(_ window: BorderWindow, to target: WindowID, thenShow: Bool) {
        let border = WindowID(window.windowNumber), display = window.display
        spaces.async {
            let ordinary = Displays.current().ordinarySpaces(on: display)
            let targetSpaces = (SkyLight.spaces(of: target) ?? []).filter(ordinary.contains)
            let borderSpaces = SkyLight.spaces(of: border) ?? []
            if let space = targetSpaces.first, Set(targetSpaces).isDisjoint(with: borderSpaces) {
                SLSMoveWindowsToManagedSpace(SkyLight.connection, [border] as CFArray, space)
                bordersLog.info("border \(border) of \(target) moved from Spaces \(borderSpaces, privacy: .public) to \(space)")
            }
            guard thenShow else { return }
            onMain {
                guard let next = self.pool.moved(window, of: target) else { return }
                window.show(next)
                window.order(.below, relativeTo: Int(target))
            }
        }
    }
}

private func ms(since began: Double) -> Double { (CACurrentMediaTime() - began) * 1000 }

/// `.transient` hides it in Mission Control, and `canHide = false` keeps it on screen when
/// another app's Hide Others hides Kosmos.
private final class BorderWindow: NSWindow {
    let display: DisplayID
    private let ring = CALayer()
    private var shown: ShownBorder?

    /// `frame` is its display's, in Accessibility's coordinates.
    init(display: DisplayID, frame: CGRect) {
        self.display = display
        super.init(contentRect: NSRect(origin: NSScreen.flipped(frame).origin, size: NSSize(width: 1, height: 1)),
                   styleMask: [.borderless], backing: .buffered, defer: false)
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
        // A new window framed, moved and then ordered in joined its display's current Space
        // (kosmos-probe borders), so a border is ordered in once while it draws nothing.
        orderFrontRegardless()
        orderOut(nil)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Into its pool. macOS can move a window ordered out, as off a display that goes, so its
    /// next show sets everything again.
    func putBack() {
        orderOut(nil)
        shown = nil
    }

    /// Draws nothing, ordered in where it is.
    func clear() {
        guard var next = shown else { return }
        next.alpha = 0
        show(next)
    }

    func show(_ next: ShownBorder) {
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
