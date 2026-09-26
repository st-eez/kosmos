import CoreGraphics
import KosmosCore

/// Where each label from 1 to `count` forms a window: the columns and rows holding at least
/// half as many of its pixels as its fullest, so stray pixels of the same color elsewhere
/// count for nothing. Nil for a label with fewer than `least` pixels.
func extents(of count: Int, in labels: [UInt8], width: Int, least: Int = 400) -> [(rect: CGRect, count: Int)?] {
    let height = labels.count / width
    var columns = [[Int]](repeating: [Int](repeating: 0, count: width), count: count + 1)
    var rows = [[Int]](repeating: [Int](repeating: 0, count: height), count: count + 1)
    labels.withUnsafeBufferPointer { labels in
        for y in 0..<height {
            for x in 0..<width {
                let label = Int(labels[y * width + x])
                guard label >= 1, label <= count else { continue }
                columns[label][x] += 1
                rows[label][y] += 1
            }
        }
    }
    func span(_ counts: [Int]) -> Range<Int> {
        let half = max(1, counts.max()! / 2)
        return counts.firstIndex { $0 >= half }!..<counts.lastIndex { $0 >= half }! + 1
    }
    return (1..<count + 1).map { label in
        let total = rows[label].reduce(0, +)
        guard total >= least else { return nil }
        let xs = span(columns[label]), ys = span(rows[label])
        return (CGRect(x: xs.lowerBound, y: ys.lowerBound, width: xs.count, height: ys.count), total)
    }
}

/// Counts of one label's pixels over any rectangle in constant time.
struct Summed {
    let width: Int
    private var sums: [Int32]

    init(_ labels: [UInt8], width: Int, where matches: (UInt8) -> Bool) {
        self.width = width
        let height = labels.count / width, stride = width + 1
        var sums = [Int32](repeating: 0, count: stride * (height + 1))
        for y in 0..<height {
            var row: Int32 = 0
            for x in 0..<width {
                if matches(labels[y * width + x]) { row += 1 }
                sums[(y + 1) * stride + x + 1] = sums[y * stride + x + 1] + row
            }
        }
        self.sums = sums
    }

    var total: Int { Int(sums[sums.count - 1]) }

    func count(_ rect: CGRect) -> Int {
        let height = sums.count / (width + 1) - 1, stride = width + 1
        let x0 = max(0, min(width, Int(rect.minX.rounded()))), x1 = max(x0, min(width, Int(rect.maxX.rounded())))
        let y0 = max(0, min(height, Int(rect.minY.rounded()))), y1 = max(y0, min(height, Int(rect.maxY.rounded())))
        return Int(sums[y1 * stride + x1] - sums[y0 * stride + x1] - sums[y1 * stride + x0] + sums[y0 * stride + x0])
    }
}

/// A window a slide moves, from where it first showed in the step to where it settled, and
/// how far along that line each frame showed it (docs/geometry.md: the slide mixes the two
/// frames' origins and sizes by one eased fraction).
public struct Track: Sendable {
    /// The palette index, or nil for the window of Steve's the run includes.
    public let window: Int?
    public let start: CGRect
    public let end: CGRect
    public var samples: [Sample] = []
    /// When the slide began, as the samples' times put it on the easing curve.
    public var began: Double?

    public struct Sample: Sendable {
        /// -1 for the state before the step.
        public let frame: Int
        public let time: Double
        /// 0 at the start, 1 at the end.
        public let progress: Double
        /// Pixels of the window outside the fitted frame plus wallpaper inside it.
        public let misfit: Int
    }

    /// The largest distance an edge travels, in pixels.
    public var distance: Double {
        max(abs(end.minX - start.minX), abs(end.maxX - start.maxX), abs(end.minY - start.minY), abs(end.maxY - start.maxY))
    }

    public func frame(at progress: Double) -> CGRect {
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * progress }
        return CGRect(x: mix(start.minX, end.minX), y: mix(start.minY, end.minY),
                      width: mix(start.width, end.width), height: mix(start.height, end.height))
    }

    /// Where the easing puts the window at a time.
    public func predicted(at time: Double) -> Double? {
        began.map { Slide.ease((time - $0) / Slide.moveDuration) }
    }

    /// The fraction of the way that fits the window's pixels best, searched in steps of half
    /// a pixel from a whole way before the start to a whole way past the end, where a write
    /// that lands before the transform following it shows the window (docs/geometry.md).
    /// Pixels of other windows count neither way, since a sliding window can pass under or
    /// over them.
    func fit(window: Summed, wallpaper: Summed) -> (progress: Double, misfit: Int) {
        let step = min(0.002, 0.5 / max(distance, 1))
        var best = Int.max, ties: [Double] = []
        for progress in stride(from: -1.2, through: 2.2, by: step) {
            let rect = frame(at: progress)
            guard rect.size.width > 0, rect.size.height > 0 else { continue }
            let misfit = window.total - window.count(rect) + wallpaper.count(rect)
            if misfit < best { (best, ties) = (misfit, [progress]) } else if misfit == best { ties.append(progress) }
        }
        return (ties[ties.count / 2], best)
    }

    /// The median of each sample's start on the easing curve, from the samples between 3% and
    /// 97% of the way, where the curve is steep enough to read a time from.
    mutating func placeOnCurve(refresh: Double) {
        let starts = samples.filter { $0.progress > 0.03 && $0.progress < 0.97 }
            .map { $0.time - Slide.moveDuration * Self.inverseEase($0.progress) }.sorted()
        if !starts.isEmpty {
            began = starts[starts.count / 2]
        } else if let moved = samples.first(where: { $0.progress >= 0.5 }) {
            // It crossed in one frame: the slide began a refresh before, at the earliest.
            began = moved.time - refresh
        }
    }

    static func inverseEase(_ progress: Double) -> Double {
        var low = 0.0, high = 1.0
        for _ in 0..<40 {
            let mid = (low + high) / 2
            if Slide.ease(mid) < progress { low = mid } else { high = mid }
        }
        return (low + high) / 2
    }
}
