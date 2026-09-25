import CoreGraphics

/// The config's `borders` table: Kosmos draws a border around each tiled and floating
/// window on screen, as JankyBorders did (docs/borders.md).
public struct BorderSettings: Equatable, Sendable {
    /// The width of the line along the window's edge, centered on the edge as JankyBorders
    /// draws its `width`: the outer half lies outside the window, and of the inner half only
    /// the point next to the edge shows, over the window's own edge.
    public var width: Double
    /// The focused window's color.
    public var active: BorderColor
    /// Every other window's color. Fully transparent, the default, gives them no border.
    public var inactive: BorderColor

    public init(width: Double = 4, active: BorderColor, inactive: BorderColor = .clear) {
        self.width = width
        self.active = active
        self.inactive = inactive
    }

    /// The color of a window with or without the focus, or nil when that color is fully
    /// transparent, which draws no border.
    public func color(focused: Bool) -> BorderColor? {
        let color = focused ? active : inactive
        return color.alpha > 0 ? color : nil
    }
}

/// An sRGB color with alpha, each component from 0 to 1.
public struct BorderColor: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public static let clear = BorderColor(red: 0, green: 0, blue: 0, alpha: 0)

    public init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// `#rrggbb`, or `#rrggbbaa` with the alpha last, as CSS writes colors.
    public init?(hex text: String) {
        guard text.first == "#", text.count == 7 || text.count == 9,
              text.dropFirst().allSatisfy(\.isHexDigit), let value = UInt32(text.dropFirst(), radix: 16) else { return nil }
        let rgba = text.count == 7 ? value << 8 | 0xFF : value
        func component(_ shift: UInt32) -> Double { Double(rgba >> shift & 0xFF) / 255 }
        self.init(red: component(24), green: component(16), blue: component(8), alpha: component(0))
    }
}

/// A window's border: a ring around its frame, and the border window that holds it. All
/// rectangles are in the top left origin coordinates Accessibility uses.
public struct Border: Equatable, Sendable {
    /// The ring's outer edge.
    public var ring: CGRect
    /// The outer edge's corner radius. The inner edge's is `cornerRadius - lineWidth`, so
    /// both are concentric with the window's corners.
    public var cornerRadius: CGFloat
    /// The ring's width, from its outer edge in.
    public var lineWidth: CGFloat
    public var color: BorderColor
    /// The display that holds the largest part of the window, where the border shows.
    public var display: DisplayID
    public var displayFrame: CGRect
    /// The border window's frame: the ring, cut to its display, so no border shows on a
    /// display the window is not on.
    public var frame: CGRect

    /// The border of a window at `frame` whose corners WindowServer rounds by `radius`, or
    /// nil when the window is on none of `displays`.
    public init?(around frame: CGRect, radius: CGFloat, width: Double, color: BorderColor, displays: [Monitor]) {
        func area(_ monitor: Monitor) -> CGFloat {
            let common = monitor.frame.intersection(frame)
            return common.isNull ? 0 : common.width * common.height
        }
        guard let display = displays.max(by: { area($0) < area($1) }), area(display) > 0 else { return nil }
        let half = CGFloat(width) / 2
        ring = frame.insetBy(dx: -half, dy: -half)
        cornerRadius = radius > 0 ? radius + half : 0
        // JankyBorders keeps 1 point of the inner half, over the window's own edge.
        lineWidth = half + min(half, 1)
        self.color = color
        self.display = display.id
        displayFrame = display.frame
        self.frame = ring.intersection(display.frame)
    }
}

extension Session {
    /// The windows that get a border, each with whether it has the focus
    /// (docs/borders.md): the tiled and floating windows of the shown workspaces, but no tile
    /// of a workspace with a fullscreen window, and the windows the user holds lifted, which
    /// have the focus. A parked window has none: minimized, hidden or in native fullscreen.
    public var bordered: [WindowID: Bool] {
        var bordered: [WindowID: Bool] = [:]
        for name in shownWorkspaces {
            let workspace = workspaces[name]!
            let tiles = workspace.fullscreenWindow == nil ? workspace.root.windows : []
            for window in tiles + workspace.floating { bordered[window] = window == focused }
        }
        for window in lifted { bordered[window] = true }
        return bordered
    }

    /// The border of each window in `bordered` whose color shows, where `shown` finds the
    /// window on screen: the frame it shows at and its corner radius, or nil for a window
    /// concealed or ordered out.
    public func borders(_ settings: BorderSettings, shown: (WindowID) -> (frame: CGRect, radius: CGFloat)?) -> [WindowID: Border] {
        var borders: [WindowID: Border] = [:]
        for (window, focused) in bordered {
            guard let color = settings.color(focused: focused), let target = shown(window),
                  let border = Border(around: target.frame, radius: target.radius, width: settings.width, color: color,
                                      displays: monitors) else { continue }
            borders[window] = border
        }
        return borders
    }
}
