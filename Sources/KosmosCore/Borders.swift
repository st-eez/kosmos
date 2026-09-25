import CoreGraphics

/// The config's `borders` (docs/borders.md).
public struct BorderSettings: Equatable, Sendable {
    /// JankyBorders' `width`, whose line is centered on the window's edge with the inner half
    /// under the window, so the border is the outer half.
    public var width: Double
    /// Nil for the macOS accent color.
    public var active: BorderColor?
    /// Fully transparent draws no border.
    public var inactive: BorderColor

    public init(width: Double = 4, active: BorderColor? = nil, inactive: BorderColor = .clear) {
        self.width = width
        self.active = active
        self.inactive = inactive
    }

    public func color(focused: Bool, accent: BorderColor) -> BorderColor? {
        let color = focused ? active ?? accent : inactive
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

/// A ring around a window's frame, and the border window that holds it. All rectangles are
/// in the top left origin coordinates Accessibility uses.
public struct Border: Equatable, Sendable {
    /// The ring's outer edge.
    public var ring: CGRect
    /// The outer edge's corner radius. The inner edge's is `cornerRadius - lineWidth`, the
    /// window's own.
    public var cornerRadius: CGFloat
    public var lineWidth: CGFloat
    public var color: BorderColor
    /// The display that holds the largest part of the window.
    public var display: DisplayID
    public var displayFrame: CGRect
    /// The ring cut to its display, so no border shows on a display the window is not on.
    public var frame: CGRect

    /// `radius` is how much WindowServer rounds the window's corners. Nil when the window is
    /// on none of `displays`.
    public init?(around frame: CGRect, radius: CGFloat, width: Double, color: BorderColor, displays: [Monitor]) {
        func area(_ monitor: Monitor) -> CGFloat {
            let common = monitor.frame.intersection(frame)
            return common.isNull ? 0 : common.width * common.height
        }
        guard let display = displays.max(by: { area($0) < area($1) }), area(display) > 0 else { return nil }
        let half = CGFloat(width) / 2
        ring = frame.insetBy(dx: -half, dy: -half)
        cornerRadius = radius > 0 ? radius + half : 0
        lineWidth = half
        self.color = color
        self.display = display.id
        displayFrame = display.frame
        self.frame = ring.intersection(display.frame)
    }
}

extension Session {
    /// Each window that gets a border, with whether it has the focus (docs/borders.md).
    public var bordered: [WindowID: Bool] {
        var bordered: [WindowID: Bool] = [:]
        let focused = self.focused
        for name in shownWorkspaces {
            let workspace = workspaces[name]!
            let tiles = workspace.fullscreenWindow == nil ? workspace.root.windows : []
            for window in tiles + workspace.floating { bordered[window] = window == focused }
        }
        for window in lifted { bordered[window] = true }
        return bordered
    }

    /// `shown` gives where a window shows and its corner radius, or nil for one concealed or
    /// ordered out.
    public func borders(_ settings: BorderSettings, accent: BorderColor,
                        shown: (WindowID) -> (frame: CGRect, radius: CGFloat)?) -> [WindowID: Border] {
        var borders: [WindowID: Border] = [:]
        for (window, focused) in bordered {
            guard let color = settings.color(focused: focused, accent: accent), let target = shown(window),
                  let border = Border(around: target.frame, radius: target.radius, width: settings.width, color: color,
                                      displays: monitors) else { continue }
            borders[window] = border
        }
        return borders
    }
}
