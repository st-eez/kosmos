import CoreGraphics

/// A frame of the screen as ScreenCaptureKit delivers it, and when it showed.
public struct Picture: Sendable {
    public let width: Int
    public let height: Int
    /// B, G, R and A from the low byte up, as `kCVPixelFormatType_32BGRA` lays them out.
    public var pixels: [UInt32]
    /// Seconds since 1970, the clock of bash's EPOCHREALTIME.
    public var time: Double

    /// Channel differences up to this much are capture noise or a sub-pixel move.
    public static let tolerance: Int32 = 24
    /// Fewer differing pixels than this are no change: a 1 point border ring around the
    /// smallest window moves hundreds.
    public static let least = 8

    public init(width: Int, height: Int, pixels: [UInt32], time: Double) {
        precondition(pixels.count == width * height)
        (self.width, self.height, self.pixels, self.time) = (width, height, pixels, time)
    }

    public init(width: Int, height: Int, fill: UInt32, time: Double = 0) {
        self.init(width: width, height: height, pixels: Array(repeating: fill, count: width * height), time: time)
    }

    public mutating func fill(_ rect: CGRect, with color: UInt32) {
        let (x0, y0, x1, y1) = clamped(rect)
        guard x0 < x1, y0 < y1 else { return }
        for y in y0..<y1 { pixels.replaceSubrange(y * width + x0..<y * width + x1, with: repeatElement(color, count: x1 - x0)) }
    }

    /// The rectangle rounded to whole pixels and cut to the picture.
    func clamped(_ rect: CGRect) -> (x0: Int, y0: Int, x1: Int, y1: Int) {
        (max(0, min(width, Int(rect.minX.rounded()))), max(0, min(height, Int(rect.minY.rounded()))),
         max(0, min(width, Int(rect.maxX.rounded()))), max(0, min(height, Int(rect.maxY.rounded()))))
    }

    /// How many pixels differ from the other picture's.
    public func differences(from other: Picture) -> Int {
        precondition(width == other.width && height == other.height)
        var count = 0
        pixels.withUnsafeBufferPointer { a in
            other.pixels.withUnsafeBufferPointer { b in
                for i in 0..<a.count where Color.differ(a[i], b[i]) { count += 1 }
            }
        }
        return count
    }
}

/// A BGRA pixel's color, as `Picture` stores it.
public enum Color {
    public static func rgb(_ red: UInt8, _ green: UInt8, _ blue: UInt8) -> UInt32 {
        0xff00_0000 | UInt32(red) << 16 | UInt32(green) << 8 | UInt32(blue)
    }

    public static func components(_ color: UInt32) -> (red: Int32, green: Int32, blue: Int32) {
        (Int32(color >> 16 & 0xff), Int32(color >> 8 & 0xff), Int32(color & 0xff))
    }

    /// The largest difference of one channel.
    @inline(__always) public static func distance(_ a: UInt32, _ b: UInt32) -> Int32 {
        let (ar, ag, ab) = components(a), (br, bg, bb) = components(b)
        return max(abs(ar - br), abs(ag - bg), abs(ab - bb))
    }

    @inline(__always) static func differ(_ a: UInt32, _ b: UInt32) -> Bool { distance(a, b) > Picture.tolerance }
}

/// The colors the bench stub paints its windows, one per window, so each window can be found
/// in a frame by its color.
public struct Palette: Sendable {
    /// Saturated sRGB colors at least 127 apart on some channel from one another and from
    /// the Tokyo Night theme's border colors, #7aa2f7 and #f7768e.
    public static let stub = Palette(colors: [
        Color.rgb(255, 0, 0), Color.rgb(0, 255, 0), Color.rgb(0, 0, 255), Color.rgb(255, 255, 0),
        Color.rgb(255, 0, 255), Color.rgb(0, 255, 255), Color.rgb(255, 128, 0), Color.rgb(128, 0, 255),
    ])

    public var colors: [UInt32]
    /// Each 15 bit color's label: 0, or a color's index plus 1.
    private let table: [UInt8]

    public init(colors: [UInt32]) {
        precondition(colors.count < Int(Label.wallpaper))
        self.colors = colors
        table = (0..<32768).map { key -> UInt8 in
            let center = Color.rgb(UInt8((key >> 10) * 8 + 4), UInt8((key >> 5 & 31) * 8 + 4), UInt8((key & 31) * 8 + 4))
            let nearest = colors.indices.min { Color.distance(colors[$0], center) < Color.distance(colors[$1], center) }
            guard let nearest, Color.distance(colors[nearest], center) <= Picture.tolerance + 4 else { return 0 }
            return UInt8(nearest + 1)
        }
    }

    /// The palette as a picture of the windows shows it: each color becomes the median of the
    /// pixels within 48 of it on every channel, where at least 1000 are, since capture can
    /// shift colors.
    public func calibrated(from picture: Picture) -> Palette {
        Palette(colors: colors.map { color in
            let near = picture.pixels.filter { Color.distance($0, color) <= 48 }
            guard near.count >= 1000 else { return color }
            func median(_ shift: UInt32) -> UInt8 { UInt8(near.map { $0 >> shift & 0xff }.sorted()[near.count / 2]) }
            return Color.rgb(median(16), median(8), median(0))
        })
    }

    @inline(__always) func label(_ pixel: UInt32) -> UInt8 {
        table[Int(pixel >> 19 & 31) << 10 | Int(pixel >> 11 & 31) << 5 | Int(pixel >> 3 & 31)]
    }
}

/// What each pixel of a frame shows: a stub window by its palette index plus 1, the
/// wallpaper, or anything else.
public enum Label {
    public static let other: UInt8 = 0
    public static let wallpaper: UInt8 = 255

    public static func of(_ picture: Picture, palette: Palette, wallpaper: Picture?) -> [UInt8] {
        var labels = [UInt8](repeating: other, count: picture.pixels.count)
        picture.pixels.withUnsafeBufferPointer { pixels in
            labels.withUnsafeMutableBufferPointer { labels in
                for i in 0..<pixels.count {
                    let label = palette.label(pixels[i])
                    if label != other {
                        labels[i] = label
                    } else if let wallpaper, !Color.differ(pixels[i], wallpaper.pixels[i]) {
                        labels[i] = Self.wallpaper
                    }
                }
            }
        }
        return labels
    }
}
