import CoreGraphics
import Foundation
import KosmosCore

/// What the run holds constant from step to step.
public struct Scene: Sendable {
    public var palette: Palette
    /// The display with the workspace empty. Pixels that match it show the desktop.
    public var wallpaper: Picture?
    /// Seconds between the display's refreshes.
    public var refresh: Double
    /// Whether a window of Steve's, which no palette color finds, is on the workspace. It is
    /// then what the stub windows, the wallpaper and the stub windows' borders leave.
    public var real: Bool

    public init(palette: Palette, wallpaper: Picture?, refresh: Double, real: Bool) {
        (self.palette, self.wallpaper, self.refresh, self.real) = (palette, wallpaper, refresh, real)
    }
}

/// What a step should show between its state before and after: one change at once, as a
/// workspace switch or a focus move, or windows sliding along the easing.
public enum Expect: String, Sendable {
    case instant, slide
}

/// A frame that a correct transition would not show.
public struct Event: Sendable {
    public enum Kind: String, Sendable {
        /// Pixels that match neither the state before nor the state after, outside every
        /// sliding window's frame.
        case flash
        /// In a step expected at once, part of the screen already as after and part still as
        /// before.
        case partial
        /// In a step expected at once, the whole screen back as before after it changed.
        case revert
        /// A window further along than the easing puts it, by 10% of its way or 8 pixels.
        case jump
        /// A window back towards where it started.
        case backward
        /// A window still for longer than a refresh while the easing moves it 2 pixels a
        /// refresh or more.
        case stall
    }

    public let kind: Kind
    public let frame: Int
    /// What the frame shows wrong: `window N` by palette index, `border`, `wallpaper` or
    /// `other`, or for a motion event the window.
    public let what: String
    public let detail: String
    /// For a stall its milliseconds, and for a jump its pixels past the easing.
    public var amount: Double?
    /// The pixels the event is about, by index, for its picture.
    public var pixels: [Int32] = []
    /// For a motion event, where the easing put the window, and where it showed.
    public var expected: CGRect?
    public var shown: CGRect?
}

public struct Row: Sendable {
    public let frame: Int
    public let time: Double
    /// Pixels that differ from the frame before, the state before the step and the state
    /// after it.
    public let changed: Int
    public let fromBefore: Int
    public let fromAfter: Int
    /// Pixels that match neither state, and of them those no sliding window explains.
    public let neither: Int
    public let flagged: Int
}

public struct Analysis: Sendable {
    /// Milliseconds from the command's send to the first changed frame.
    public var latency: Double?
    /// Changed frames from the first to the last.
    public var frames: Int
    /// Milliseconds from the first changed frame to the last.
    public var span: Double
    /// Milliseconds from the send to the start of the earliest slide.
    public var began: Double?
    public var events: [Event]
    public var rows: [Row]
    public var tracks: [Track]
}

/// Measures one step from the frame before its command and the changed frames after it,
/// the last of them the settled state.
public func analyze(_ expect: Expect, sent: Double, before: Picture, frames: [Picture], scene: Scene) -> Analysis {
    guard let after = frames.last else {
        return Analysis(latency: nil, frames: 0, span: 0, began: nil, events: [], rows: [], tracks: [])
    }
    let width = before.width
    let states = (before: Shown(before, scene: scene), after: Shown(after, scene: scene))
    let shown = frames.map { Shown($0, scene: scene) }
    var tracks = expect == .slide ? slides(states, frames: shown, scene: scene, width: width) : []
    var events: [Event] = []
    for index in tracks.indices {
        tracks[index].placeOnCurve(refresh: scene.refresh)
        events += motion(tracks[index], refresh: scene.refresh)
    }
    let own = appDrawn(states, real: scene.real, width: width)

    var rows: [Row] = []
    for (index, frame) in frames.enumerated() {
        let previous = index == 0 ? before : frames[index - 1]
        var neither: [Int32] = [], pending: [Int32] = [], done: [Int32] = []
        var fromBefore = 0, fromAfter = 0
        for i in frame.pixels.indices {
            let b = Color.differ(frame.pixels[i], before.pixels[i]), a = Color.differ(frame.pixels[i], after.pixels[i])
            if b { fromBefore += 1 }
            if a { fromAfter += 1 }
            guard !own[i] else { continue }
            if a && b { neither.append(Int32(i)) } else if a { pending.append(Int32(i)) } else if b { done.append(Int32(i)) }
        }
        let last = index == frames.count - 1
        var flagged: [Int32] = []
        let rings = (states.before.rects + states.after.rects + shown[index].rects).compactMap { $0 }
            + tracks.compactMap { track in track.samples.first { $0.frame == index }.map { track.frame(at: $0.progress) } }
        func describe(_ pixels: [Int32], _ labels: [UInt8]) -> (what: String, detail: String) {
            describePixels(pixels, labels: labels, rings: rings, width: width)
        }
        switch expect {
        case .instant where !last && neither.count + done.count < Picture.least:
            events.append(Event(kind: .revert, frame: index, what: "all", detail: "the screen shows the state before again"))
        case .instant where !last && neither.count + pending.count >= Picture.least:
            if neither.count >= Picture.least {
                flagged = neither
                let (what, detail) = describe(neither, shown[index].labels)
                events.append(Event(kind: .flash, frame: index, what: what, detail: detail, pixels: neither))
            } else {
                flagged = pending
                let (what, detail) = describe(pending, states.before.labels), (_, gone) = describe(done, states.after.labels)
                events.append(Event(kind: .partial, frame: index, what: what,
                                    detail: "still as before: \(detail); as after: \(gone)", pixels: pending))
            }
        case .slide where !last && neither.count >= Picture.least:
            flagged = unexplained(neither, frame: index, labels: shown[index].labels, tracks: tracks, width: width)
            if flagged.count >= Picture.least {
                let (what, detail) = describe(flagged, shown[index].labels)
                events.append(Event(kind: .flash, frame: index, what: what, detail: detail, pixels: flagged))
            } else {
                flagged = []
            }
        default: break
        }
        rows.append(Row(frame: index, time: frame.time, changed: frame.differences(from: previous), fromBefore: fromBefore,
                        fromAfter: fromAfter, neither: neither.count, flagged: flagged.count))
    }
    let began = tracks.compactMap(\.began).min().map { ($0 - sent) * 1000 }
    return Analysis(latency: (frames[0].time - sent) * 1000, frames: frames.count,
                    span: (after.time - frames[0].time) * 1000, began: began,
                    events: events.sorted { ($0.frame, $0.kind.rawValue) < ($1.frame, $1.kind.rawValue) }, rows: rows, tracks: tracks)
}

/// The windows that move between the states, each from where it first shows: where it was
/// before, or for a window new to the screen the first frame that shows it whole, as where its
/// app opened it. A window that settles within 2 pixels of its start does not move.
private func slides(_ states: (before: Shown, after: Shown), frames: [Shown], scene: Scene, width: Int) -> [Track] {
    func moved(_ a: CGRect, _ b: CGRect) -> Bool {
        max(abs(a.minX - b.minX), abs(a.maxX - b.maxX), abs(a.minY - b.minY), abs(a.maxY - b.maxY)) > 2
    }
    // A window's first frame, or nil for one there before the step.
    var tracks: [(track: Track, first: Int?)] = []
    for window in states.after.rects.indices {
        guard let end = states.after.rects[window] else { continue }
        if let start = states.before.rects[window] {
            if moved(start, end) { tracks.append((Track(window: window, start: start, end: end), nil)) }
        } else if let first = frames.firstIndex(where: { $0.isWhole(window) }), let start = frames[first].rects[window], moved(start, end) {
            tracks.append((Track(window: window, start: start, end: end), first))
        }
    }
    if scene.real, let start = states.before.real?.rect, let end = states.after.real?.rect, moved(start, end) {
        tracks.append((Track(window: nil, start: start, end: end), nil))
    }
    // A window that starts where it was before is there a refresh before the first change,
    // so a first frame that already shows it far along counts as a jump.
    for t in tracks.indices where tracks[t].first == nil {
        tracks[t].track.samples.append(Track.Sample(frame: -1, time: frames[0].picture.time - scene.refresh, progress: 0, misfit: 0))
    }
    for (index, frame) in frames.enumerated() {
        let wallpaper = Summed(frame.labels, width: width) { $0 == Label.wallpaper }
        for t in tracks.indices where index >= tracks[t].first ?? 0 {
            let summed = if let window = tracks[t].track.window {
                Summed(frame.labels, width: width) { $0 == UInt8(window + 1) }
            } else {
                Summed(frame.realMask(width: width), width: width) { $0 == 1 }
            }
            let (progress, misfit) = tracks[t].track.fit(window: summed, wallpaper: wallpaper)
            let rect = tracks[t].track.frame(at: progress)
            // Hidden under other windows, or not yet opaque in a pop, it gives no position.
            guard summed.total * 4 >= Int(rect.width * rect.height) else { continue }
            tracks[t].track.samples.append(Track.Sample(frame: index, time: frame.picture.time, progress: progress, misfit: misfit))
        }
    }
    return tracks.map(\.track)
}

/// A picture with what each pixel shows and where each stub window is.
struct Shown {
    let picture: Picture
    let labels: [UInt8]
    let extents: [(rect: CGRect, count: Int)?]
    var rects: [CGRect?] { extents.map { $0?.rect } }

    init(_ picture: Picture, scene: Scene) {
        self.picture = picture
        labels = Label.of(picture, palette: scene.palette, wallpaper: scene.wallpaper)
        extents = KosmosBench.extents(of: scene.palette.colors.count, in: labels, width: picture.width)
    }

    /// Whether the window's color fills 80% of its extent, as it does once opaque and in
    /// front, less its rounded corners.
    func isWhole(_ window: Int) -> Bool {
        extents[window].map { Double($0.count) >= 0.8 * $0.rect.width * $0.rect.height } ?? false
    }

    /// 1 where Steve's window shows: pixels no label names, 3 or more outside every stub
    /// window, so its ring and anti-aliased edge count for nothing.
    func realMask(width: Int) -> [UInt8] {
        var mask = labels.map { $0 == Label.other ? UInt8(1) : 0 }
        for rect in rects.compactMap({ $0 }) {
            let (x0, y0, x1, y1) = picture.clamped(rect.insetBy(dx: -3, dy: -3))
            for y in y0..<y1 { for x in x0..<x1 { mask[y * width + x] = 0 } }
        }
        return mask
    }

    var real: (rect: CGRect, count: Int)? { KosmosBench.extents(of: 1, in: realMask(width: picture.width), width: picture.width)[0] }
}

/// Jumps, backward moves and stalls of one window against the easing.
private func motion(_ track: Track, refresh: Double) -> [Event] {
    let distance = track.distance
    guard track.began != nil else { return [] }
    let name = track.window.map { "window \($0)" } ?? "Steve's window"
    var events: [Event] = []
    var lastMove = track.samples.first
    for (a, b) in zip(track.samples, track.samples.dropFirst()) {
        let observed = (b.progress - a.progress) * distance
        let expected = (track.predicted(at: b.time)! - track.predicted(at: a.time)!) * distance
        let shown = track.frame(at: b.progress), eased = track.frame(at: track.predicted(at: b.time)!)
        if observed - expected > max(8, 0.1 * distance) {
            events.append(Event(kind: .jump, frame: b.frame, what: name,
                                detail: String(format: "%@ moved %.0f px in %.1f ms where the easing gave %.0f", name, observed,
                                               (b.time - a.time) * 1000, expected),
                                amount: observed - expected, expected: eased, shown: shown))
        } else if observed < -max(4, 0.05 * distance) {
            events.append(Event(kind: .backward, frame: b.frame, what: name,
                                detail: String(format: "%@ moved %.0f px back in %.1f ms", name, -observed, (b.time - a.time) * 1000),
                                amount: -observed, expected: eased, shown: shown))
        }
        guard abs(observed) >= 0.75, let from = lastMove else { continue }
        lastMove = b
        let gap = b.time - from.time
        let due = (track.predicted(at: from.time + refresh)! - track.predicted(at: from.time)!) * distance
        if gap > 1.5 * refresh, due >= 2 {
            events.append(Event(kind: .stall, frame: b.frame, what: name,
                                detail: String(format: "%@ still for %.1f ms where the easing moves it %.0f px a refresh", name,
                                               (gap - refresh) * 1000, due),
                                amount: (gap - refresh) * 1000, expected: eased, shown: shown))
        }
    }
    return events
}

/// Inside a window that stays put, what its app draws: the stub's title bar buttons, which
/// change with its key state, and everything in Steve's window. A pixel of a stub window's
/// color counts, so another window drawn over it does too.
private func appDrawn(_ states: (before: Shown, after: Shown), real: Bool, width: Int) -> [Bool] {
    var own = [Bool](repeating: false, count: states.before.labels.count)
    func stays(_ a: CGRect?, _ b: CGRect?) -> CGRect? {
        guard let a, let b, max(abs(a.minX - b.minX), abs(a.maxX - b.maxX), abs(a.minY - b.minY), abs(a.maxY - b.maxY)) <= 1 else {
            return nil
        }
        return a.insetBy(dx: 2, dy: 2)
    }
    func mark(_ rect: CGRect, where drawn: (Int) -> Bool) {
        let (x0, y0, x1, y1) = states.before.picture.clamped(rect)
        for y in y0..<y1 { for x in x0..<x1 where drawn(y * width + x) { own[y * width + x] = true } }
    }
    for (a, b) in zip(states.before.rects, states.after.rects) {
        guard let rect = stays(a, b) else { continue }
        mark(rect) { states.before.labels[$0] == Label.other || states.after.labels[$0] == Label.other }
    }
    if real, let rect = stays(states.before.real?.rect, states.after.real?.rect) { mark(rect) { _ in true } }
    return own
}

/// Of the pixels that match neither state, those outside every sliding window's frame in
/// this frame, and outside the wallpaper its path uncovers. A window with no position in
/// this frame explains its whole path.
private func unexplained(_ neither: [Int32], frame: Int, labels: [UInt8], tracks: [Track], width: Int) -> [Int32] {
    var explained: [CGRect] = [], uncovered: [CGRect] = []
    for track in tracks {
        let path = track.start.union(track.end).insetBy(dx: -3, dy: -3)
        uncovered.append(path)
        if let sample = track.samples.first(where: { $0.frame == frame }) {
            explained.append(track.frame(at: sample.progress).insetBy(dx: -3, dy: -3))
        } else {
            explained.append(path)
        }
    }
    return neither.filter { i in
        let point = CGPoint(x: Int(i) % width, y: Int(i) / width)
        if explained.contains(where: { $0.contains(point) }) { return false }
        return !(labels[Int(i)] == Label.wallpaper && uncovered.contains { $0.contains(point) })
    }
}

/// The largest groups of the pixels by what they show, and where they are: the ring outside
/// a stub window's edge counts as `border`.
func describePixels(_ pixels: [Int32], labels: [UInt8], rings: [CGRect], width: Int) -> (what: String, detail: String) {
    guard !pixels.isEmpty else { return ("none", "none") }
    var counts: [String: Int] = [:]
    var box = CGRect.null
    for i in pixels {
        let point = CGPoint(x: Int(i) % width, y: Int(i) / width)
        box = box.union(CGRect(origin: point, size: CGSize(width: 1, height: 1)))
        let what = switch labels[Int(i)] {
        case Label.wallpaper: "wallpaper"
        case Label.other where rings.contains(where: { $0.insetBy(dx: -3, dy: -3).contains(point) && !$0.insetBy(dx: 1, dy: 1).contains(point) }):
            "border"
        case Label.other: "other"
        case let window: "window \(window - 1)"
        }
        counts[what, default: 0] += 1
    }
    let ranked = counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
    let parts = ranked.prefix(3).map { "\($0.key) \($0.value) px" }.joined(separator: ", ")
    return (ranked[0].key, "\(parts) in \(Int(box.minX)),\(Int(box.minY)) \(Int(box.width))x\(Int(box.height))")
}
