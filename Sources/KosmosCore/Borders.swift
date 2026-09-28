import CoreGraphics

/// The config's `borders` (docs/borders.md).
public struct BorderSettings: Equatable, Sendable {
    /// In points, the ring's thickness outside the window's edge (docs/borders.md).
    public var width: Double = 2
    /// Nil for the macOS accent color.
    public var active: BorderColor?
    /// Fully transparent draws no border.
    public var inactive: BorderColor = .clear
    /// A window flashes it when its app refuses its tile. Nil for the macOS system red, and
    /// fully transparent for no flash.
    public var warning: BorderColor?

    public init() {}

    public func color(focused: Bool, flashing: Bool, accent: BorderColor, red: BorderColor) -> BorderColor? {
        // A transparent warning leaves the window its own color.
        if flashing, (warning ?? red).alpha > 0 { return warning ?? red }
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
    /// While the window slides, each other display the slide can still show it on
    /// (docs/borders.md).
    public var slideDisplays: [Monitor]

    /// `radius` is how much WindowServer rounds the window's corners, and `path`, while the
    /// window slides, holds every frame the slide can still show it at. Nil when the window
    /// is on none of `displays`.
    public init?(around frame: CGRect, radius: CGFloat, width: Double, color: BorderColor, displays: [Monitor],
                 path: CGRect? = nil) {
        guard let index = Self.display(holding: frame, of: displays) else { return nil }
        let display = displays[index]
        slideDisplays = path.map { path in displays.filter { $0.id != display.id && Self.area(of: path, on: $0) > 0 } } ?? []
        lineWidth = CGFloat(width)
        ring = frame.insetBy(dx: -lineWidth, dy: -lineWidth)
        cornerRadius = radius > 0 ? radius + lineWidth : 0
        self.color = color
        self.display = display.id
        displayFrame = display.frame
        self.frame = ring.intersection(display.frame)
    }

    /// The index in `displays` of the one that holds the largest part of `frame`, or nil when
    /// none holds any of it.
    public static func display(holding frame: CGRect, of displays: [Monitor]) -> Int? {
        guard let index = displays.indices.max(by: { area(of: frame, on: displays[$0]) < area(of: frame, on: displays[$1]) }),
              area(of: frame, on: displays[index]) > 0 else { return nil }
        return index
    }

    private static func area(of rect: CGRect, on monitor: Monitor) -> CGFloat {
        let common = monitor.frame.intersection(rect)
        return common.isNull ? 0 : common.width * common.height
    }
}

/// A sliding window's ring, which each display frame of the slide places in one of the border
/// windows BorderPool gave the window, each covering its own display (docs/borders.md).
public struct SlideRing: Equatable, Sendable {
    public var lineWidth: CGFloat
    /// The display each border window covers.
    public var displays: [Monitor]

    public init(lineWidth: CGFloat, displays: [Monitor]) {
        self.lineWidth = lineWidth
        self.displays = displays
    }

    /// The index of the window that shows the ring around `shown`, the one on the display
    /// holding the largest part of it, as a border at rest goes, and the ring's frame in that
    /// window's layer, from the window's bottom left. Nil when none of the displays holds any of
    /// it.
    public func place(around shown: CGRect) -> (index: Int, frame: CGRect)? {
        guard let index = Border.display(holding: shown, of: displays) else { return nil }
        let ring = shown.insetBy(dx: -lineWidth, dy: -lineWidth), display = displays[index].frame
        return (index, CGRect(x: ring.minX - display.minX, y: display.maxY - ring.maxY, width: ring.width, height: ring.height))
    }
}

/// A border as its window shows it.
public struct ShownBorder: Equatable, Sendable {
    public var border: Border
    public var level: Int32
    public var alpha: Double
    /// While the target slides, its border window covers its display and each display frame
    /// moves only the ring's layer, a fourth of the cost of moving the window (docs/borders.md).
    public var sliding: Bool

    public init(border: Border, level: Int32, alpha: Double, sliding: Bool) {
        self.border = border
        self.level = level
        self.alpha = alpha
        self.sliding = sliding
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
            for window in tiles + workspace.floating where window != workspace.fullscreenWindow {
                bordered[window] = window == focused
            }
        }
        for window in lifted { bordered[window] = true }
        return bordered
    }

    /// `shown` gives where a window shows, its corner radius and, while it slides, its slide's
    /// path, or nil for one concealed or ordered out. `flashing` names the windows whose app
    /// just refused their tile.
    public func borders(_ settings: BorderSettings, accent: BorderColor, red: BorderColor, flashing: Set<WindowID>,
                        shown: (WindowID) -> (frame: CGRect, radius: CGFloat, path: CGRect?)?) -> [WindowID: Border] {
        var borders: [WindowID: Border] = [:]
        for (window, focused) in bordered {
            guard let color = settings.color(focused: focused, flashing: flashing.contains(window), accent: accent, red: red),
                  let target = shown(window),
                  let border = Border(around: target.frame, radius: target.radius, width: settings.width, color: color,
                                      displays: monitors, path: target.path) else { continue }
            borders[window] = border
        }
        return borders
    }
}

extension Session {
    /// Of a plan's `targets`, the tiles on shown workspaces whose target is longer than the
    /// tile on an axis along which a target `written` moves from `now`, where WindowServer has
    /// the window, or along which the tile moved from `tiles`, where the last plan had it: the
    /// app refuses its tile, and the border flashes (docs/borders.md). `tiles` takes the new
    /// tiles and forgets windows that left.
    public func spilling(_ targets: [WindowID: CGRect], written: Set<WindowID>, tiles: inout [WindowID: CGRect],
                         now: (WindowID) -> CGRect?) -> Set<WindowID> {
        var shown: [String: [WindowID: CGRect]] = [:]
        var spilling: Set<WindowID> = []
        for (window, target) in targets {
            guard let name = home[window], isShown(name), workspaces[name]!.fullscreenWindow == nil else { continue }
            if shown[name] == nil {
                let monitor = monitor(of: name)
                shown[name] = workspaces[name]!.tileFrames(in: monitor.area, gaps: monitor.gaps)
            }
            guard let tile = shown[name]![window] else { continue }
            let last = tiles.updateValue(tile, forKey: window), was = written.contains(window) ? now(window) : target
            func refused(_ span: (CGRect) -> (CGFloat, CGFloat)) -> Bool {
                span(target).1 > span(tile).1
                    && (was.map { span($0) != span(target) } != false || last.map { span($0) != span(tile) } == true)
            }
            if refused({ ($0.minX, $0.width) }) || refused({ ($0.minY, $0.height) }) { spilling.insert(window) }
        }
        tiles = tiles.filter { home[$0.key] != nil }
        return spilling
    }
}
