import CoreGraphics
import Foundation
import KosmosCore
import Testing
@testable import KosmosBench

// Synthetic frames at 120 Hz: a wallpaper gradient, stub windows in the palette's colors,
// the focused window's border as a 1 pixel ring in Tokyo Night's accent, and Steve's window
// as a gray checkerboard.

private let refresh = 1.0 / 120
private let sent = 1000.0
/// The first refresh at which the slide shows: 20 ms after the send.
private let began = sent + 0.02
private let wallpaper = Picture(width: 240, height: 150, pixels: (0..<240 * 150).map { (i: Int) -> UInt32 in
    let x = UInt8(i % 240 / 8), y = UInt8(i / 240 / 5)
    return Color.rgb(30 + x, 40, 70 + y)
}, time: 0)
private let scene = Scene(palette: .stub, wallpaper: wallpaper, refresh: refresh, real: false)
private let accent = Color.rgb(0x7a, 0xa2, 0xf7)

// The windows leave the bottom of the picture free.
private let left = CGRect(x: 10, y: 10, width: 100, height: 90)
private let right = CGRect(x: 130, y: 10, width: 100, height: 90)
private let wide = CGRect(x: 10, y: 10, width: 150, height: 90)
private let narrow = CGRect(x: 170, y: 10, width: 60, height: 90)

private struct Shape {
    var window: Int?
    var rect: CGRect
    var border = false
}

private func picture(_ shapes: [Shape], at time: Double) -> Picture {
    var picture = wallpaper
    picture.time = time
    for shape in shapes {
        if shape.border { picture.fill(shape.rect.insetBy(dx: -1, dy: -1), with: accent) }
        if let window = shape.window {
            picture.fill(shape.rect, with: Palette.stub.colors[window])
        } else {
            let (x0, y0, x1, y1) = picture.clamped(shape.rect)
            for y in y0..<y1 {
                for x in x0..<x1 { picture.pixels[y * 240 + x] = (x / 4 + y / 4) % 2 == 0 ? Color.rgb(200, 200, 200) : Color.rgb(60, 60, 60) }
            }
        }
    }
    return picture
}

/// The frames as the capture keeps them: through `Screen`, which drops unchanged ones.
private func record(before: [Shape], _ frames: [Picture]) -> (before: Picture, frames: [Picture]) {
    var screen = Screen()
    screen.add(picture(before, at: sent - 1))
    screen.arm()
    frames.forEach { screen.add($0) }
    #expect(screen.settled(sent: sent, at: max(frames.last!.time + Screen.quiet, sent + Screen.shortest)) == .settled)
    return screen.take(sent: sent)!
}

/// Frames every refresh from `began` for 0.5 s, with each shape's rect eased from `from`.
/// `showing` can put a window elsewhere along its way in a frame.
private func slide(_ shapes: [Shape], from: [CGRect?], showing: (Int, Double) -> Double? = { _, _ in nil }) -> [Picture] {
    (0..<60).map { index in
        let time = began + Double(index) * refresh
        let eased = Slide.ease((time - began + refresh) / Slide.moveDuration)
        return picture(shapes.enumerated().map { number, shape in
            guard let start = from[number] else { return shape }
            let track = Track(window: shape.window, start: start, end: shape.rect)
            return Shape(window: shape.window, rect: track.frame(at: showing(index, eased) ?? eased), border: shape.border)
        }, at: time)
    }
}

private let before = [Shape(window: 0, rect: left, border: true), Shape(window: 1, rect: right)]
private let after = [Shape(window: 0, rect: wide, border: true), Shape(window: 1, rect: narrow)]
private let other = [Shape(window: 2, rect: left, border: true), Shape(window: 3, rect: right)]

@Test func aCleanSlideRaisesNothing() {
    let (first, frames) = record(before: before, slide(after, from: [left, right]))
    let analysis = analyze(.slide, sent: sent, before: first, frames: frames, scene: scene)
    #expect(analysis.events.isEmpty, "\(analysis.events.map(\.detail))")
    #expect(analysis.tracks.count == 2)
    #expect(abs(analysis.latency! - 20) < 0.1)
    #expect(abs(analysis.began! - 20 + refresh * 1000) < 3)
    #expect(analysis.frames > 20)
}

@Test func missedRefreshesAreAStall() {
    let frames = slide(after, from: [left, right]).enumerated().filter { ![3, 4, 5].contains($0.offset) }.map(\.element)
    let (first, kept) = record(before: before, frames)
    let analysis = analyze(.slide, sent: sent, before: first, frames: kept, scene: scene)
    let stalls = analysis.events.filter { $0.kind == .stall }
    #expect(stalls.count == 2, "one per window: \(analysis.events.map(\.detail))")
    #expect(stalls.allSatisfy { abs($0.amount! - 3 * refresh * 1000) < 0.1 })
    #expect(analysis.events.allSatisfy { $0.kind == .stall })
}

@Test func aWindowAheadOfTheEasingIsAJump() {
    // Both windows show at their end from the fifth frame on, as if their writes had landed
    // with no transform.
    let frames = slide(after, from: [left, right]) { index, _ in index >= 4 ? 1 : nil }
    let (first, kept) = record(before: before, frames)
    let analysis = analyze(.slide, sent: sent, before: first, frames: kept, scene: scene)
    let jumps = analysis.events.filter { $0.kind == .jump }
    #expect(jumps.count == 2, "\(analysis.events.map(\.detail))")
    #expect(jumps.allSatisfy { $0.frame == 4 })
    #expect(!analysis.events.contains { $0.kind == .stall || $0.kind == .flash })
}

@Test func aSlideThatNeverHappenedIsAJump() {
    let frames = slide(after, from: [left, right]) { _, _ in 1 }
    let (first, kept) = record(before: before, frames)
    let analysis = analyze(.slide, sent: sent, before: first, frames: kept, scene: scene)
    #expect(analysis.events.filter { $0.kind == .jump }.map(\.frame) == [0, 0], "\(analysis.events.map(\.detail))")
}

@Test func aWriteLandingAheadOfItsTransformIsADisplacedFrame() {
    // In the seventh frame window 1 shows offset by its whole move, where WindowServer draws it
    // between its write landing and the read that sets its transform (docs/geometry.md).
    let frames = slide(after, from: [left, right]) { index, eased in index == 6 ? eased + 1 : nil }
    let (first, kept) = record(before: before, frames)
    let analysis = analyze(.slide, sent: sent, before: first, frames: kept, scene: scene)
    #expect(analysis.events.map(\.kind) == [.displaced, .displaced], "\(analysis.events.map(\.detail))")
    #expect(analysis.events.allSatisfy { $0.frame == 6 })
}

@Test func aSwitchTimesItsWindowsBorderAndKey() {
    // The windows show, the border a refresh later, and the title bar buttons turn from gray to
    // the key window's colors a refresh after that.
    let buttons = CGRect(x: 14, y: 12, width: 12, height: 4)
    var windows = picture([Shape(window: 2, rect: left), Shape(window: 3, rect: right)], at: began)
    var bordered = picture(other, at: began + refresh)
    var keyed = picture(other, at: began + 2 * refresh)
    windows.fill(buttons, with: Color.rgb(200, 200, 200))
    bordered.fill(buttons, with: Color.rgb(200, 200, 200))
    keyed.fill(buttons, with: Color.rgb(250, 90, 80))
    let start = [Shape(window: 0, rect: left), Shape(window: 1, rect: right, border: true)]
    let (first, kept) = record(before: start, [windows, bordered, keyed])
    let analysis = analyze(.instant, sent: sent, before: first, frames: kept, scene: scene)
    #expect(abs(analysis.windows! - 20) < 0.1 && abs(analysis.border! - 20 - refresh * 1000) < 0.1
        && abs(analysis.keyed! - 20 - 2 * refresh * 1000) < 0.1, "\(analysis.windows ?? -1) \(analysis.border ?? -1) \(analysis.keyed ?? -1)")
    #expect(analysis.events.map(\.kind) == [.partial] && analysis.events.first?.what == "border", "\(analysis.events.map(\.detail))")

    // With the border where it was before, its absence in the first frame is a blink.
    let (blinkFirst, blinkKept) = record(before: before, [windows, bordered, keyed])
    let blink = analyze(.instant, sent: sent, before: blinkFirst, frames: blinkKept, scene: scene)
    #expect(blink.events.map(\.kind) == [.flash] && blink.events.first?.what == "border", "\(blink.events.map(\.detail))")
}

@Test func aWindowWhereNeitherStateHasItIsAFlash() {
    // A hidden workspace's window shows for one frame below the others.
    var frames = slide(after, from: [left, right])
    frames[6].fill(CGRect(x: 20, y: 110, width: 60, height: 30), with: Palette.stub.colors[2])
    let (first, kept) = record(before: before, frames)
    let analysis = analyze(.slide, sent: sent, before: first, frames: kept, scene: scene)
    #expect(analysis.events.map(\.kind) == [.flash], "\(analysis.events.map(\.detail))")
    #expect(analysis.events.first?.what == "window 2")
    #expect(analysis.events.first?.frame == 6)
}

@Test func aNewWindowSlidesFromWhereItsAppOpenedIt() {
    // The app shows its window below the others two refreshes before Kosmos slides it into
    // the right third, while the others make room.
    let opened = CGRect(x: 90, y: 110, width: 60, height: 35)
    let tiles = [CGRect(x: 10, y: 10, width: 67, height: 90), CGRect(x: 87, y: 10, width: 66, height: 90),
                 CGRect(x: 163, y: 10, width: 67, height: 90)]
    let shapes = [Shape(window: 0, rect: tiles[0], border: true), Shape(window: 1, rect: tiles[1]), Shape(window: 2, rect: tiles[2])]
    let frames = [picture(before + [Shape(window: 2, rect: opened)], at: began - 2 * refresh)] + slide(shapes, from: [left, right, opened])
    let (first, kept) = record(before: before, frames)
    let analysis = analyze(.slide, sent: sent, before: first, frames: kept, scene: scene)
    #expect(analysis.events.isEmpty, "\(analysis.events.map(\.detail))")
    #expect(analysis.tracks.map(\.window) == [0, 1, 2])
    #expect(analysis.tracks[2].samples.first?.frame == 0 && analysis.tracks[2].start == opened)
}

@Test func whatAnAppDrawsInItsWindowIsItsOwn() {
    // The title bar buttons of the window that loses the key turn gray a refresh after the
    // border moves on.
    let buttons = CGRect(x: 14, y: 12, width: 12, height: 4)
    let moved = [Shape(window: 0, rect: left), Shape(window: 1, rect: right, border: true)]
    var screen = Screen()
    var start = picture(before, at: sent - 1), late = picture(moved, at: began), settled = picture(moved, at: began + refresh)
    start.fill(buttons, with: Color.rgb(250, 90, 80))
    late.fill(buttons, with: Color.rgb(250, 90, 80))
    settled.fill(buttons, with: Color.rgb(200, 200, 200))
    screen.add(start)
    screen.arm()
    [late, settled].forEach { screen.add($0) }
    let (first, kept) = screen.take(sent: sent)!
    #expect(kept.count == 2)
    #expect(analyze(.instant, sent: sent, before: first, frames: kept, scene: scene).events.isEmpty)
}

@Test func aSwitchInOneFrameRaisesNothing() {
    let (first, kept) = record(before: before, [picture(other, at: began)])
    let analysis = analyze(.instant, sent: sent, before: first, frames: kept, scene: scene)
    #expect(analysis.events.isEmpty)
    #expect(analysis.frames == 1)
    #expect(abs(analysis.latency! - 20) < 0.1)
}

@Test func aBlankFrameInASwitchIsAFlash() {
    let (first, kept) = record(before: before, [picture([], at: began), picture(other, at: began + refresh)])
    let analysis = analyze(.instant, sent: sent, before: first, frames: kept, scene: scene)
    #expect(analysis.events.map(\.kind) == [.flash])
    #expect(analysis.events.first?.what == "wallpaper")
}

@Test func windowsAtTheirOldTilesInASwitchAreAFlash() {
    // The revealed windows show at their old tiles for a frame, then jump.
    let old = [Shape(window: 2, rect: CGRect(x: 60, y: 10, width: 60, height: 60)), Shape(window: 3, rect: CGRect(x: 60, y: 80, width: 60, height: 60))]
    let (first, kept) = record(before: before, [picture(old, at: began), picture(other, at: began + refresh)])
    let analysis = analyze(.instant, sent: sent, before: first, frames: kept, scene: scene)
    #expect(analysis.events.map(\.kind) == [.flash])
    #expect(analysis.events.first.map { $0.detail.contains("window 2") && $0.detail.contains("window 3") } == true)
}

@Test func aBorderLateToMoveIsAPartialFrame() {
    let moved = [Shape(window: 0, rect: left), Shape(window: 1, rect: right, border: true)]
    let both = [Shape(window: 0, rect: left, border: true), Shape(window: 1, rect: right, border: true)]
    let (first, kept) = record(before: before, [picture(both, at: began), picture(moved, at: began + refresh)])
    let analysis = analyze(.instant, sent: sent, before: first, frames: kept, scene: scene)
    #expect(analysis.events.map(\.kind) == [.partial])
    #expect(analysis.events.first?.what == "border")
}

@Test func aSwitchThatComesBackIsARevert() {
    let frames = [picture(other, at: began), picture(before, at: began + refresh), picture(other, at: began + 2 * refresh)]
    let (first, kept) = record(before: before, frames)
    let analysis = analyze(.instant, sent: sent, before: first, frames: kept, scene: scene)
    #expect(analysis.events.map(\.kind) == [.revert])
}

@Test func stevesWindowIsTrackedByWhatTheStubsLeave() {
    let scene = Scene(palette: .stub, wallpaper: wallpaper, refresh: refresh, real: true)
    let before = [Shape(window: nil, rect: left), Shape(window: 1, rect: right, border: true)]
    let after = [Shape(window: nil, rect: wide), Shape(window: 1, rect: narrow, border: true)]
    let (first, kept) = record(before: before, slide(after, from: [left, right]))
    let clean = analyze(.slide, sent: sent, before: first, frames: kept, scene: scene)
    #expect(clean.events.isEmpty, "\(clean.events.map(\.detail))")
    #expect(clean.tracks.map(\.window) == [1, nil])

    let jumped = slide(after, from: [left, right]) { index, _ in index >= 4 ? 1 : nil }
    let (start, frames) = record(before: before, jumped)
    let analysis = analyze(.slide, sent: sent, before: start, frames: frames, scene: scene)
    #expect(analysis.events.filter { $0.kind == .jump }.map(\.what).sorted() == ["Steve's window", "window 1"],
            "\(analysis.events.map(\.detail))")
}

@Test func aStepThatChangesNothingEndsUnchanged() {
    var screen = Screen()
    screen.add(picture(before, at: sent - 1))
    screen.arm()
    #expect(screen.settled(sent: sent, at: sent + 1) == nil)
    #expect(screen.settled(sent: sent, at: sent + Screen.unchanged) == .unchanged)
    #expect(screen.take(sent: sent)?.frames.isEmpty == true)
}

@Test func aStepStillChangingIsCut() {
    var screen = Screen()
    screen.add(picture(before, at: sent - 1))
    screen.arm()
    screen.add(picture([], at: sent + 3.9))
    #expect(screen.settled(sent: sent, at: sent + 3.95) == nil)
    #expect(screen.settled(sent: sent, at: sent + Screen.longest) == .cut)
}

@Test func calibrationFollowsAShiftedCapture() {
    let shifted = Picture(width: 100, height: 20, fill: Color.rgb(230, 30, 20))
    let palette = Palette.stub.calibrated(from: shifted)
    #expect(palette.colors[0] == Color.rgb(230, 30, 20))
    #expect(palette.colors[1] == Palette.stub.colors[1])
}

@Test func kosmosLogLinesGiveTheStepsFacts() throws {
    let text = """
        2026-09-26 00:59:28.257 Df Kosmos[20670:2488082] [io.github.st-eez.kosmos:controller] switch to 6: 1 shown, 1 hidden (0 stripped), before bridge 0.150 ms, held 4.500 ms, bridge 39.036 ms (queued 0.039, sent 2.314, confirmed 35.565 by read, recovered 0.001, back 0.104), total 39.187 ms, confirmed
        2026-09-26 00:59:28.300 I  Kosmos[20670:2488082] [io.github.st-eez.kosmos:slide] relayout: 2 windows slide, 1 jump, 6 Spaces free
        2026-09-26 00:59:28.310 I  Kosmos[20670:2488083] [io.github.st-eez.kosmos:app] 4242 written, AX time 0.41 ms
        2026-09-26 00:59:28.700 I  Kosmos[20670:2488082] [io.github.st-eez.kosmos:slide] 4242 slid in 45 frames, landed 12.5 ms after its write
        2026-09-26 00:59:28.701 I  Kosmos[20670:2488082] [io.github.st-eez.kosmos:slide] 4243 popped in 49 frames, did not land
        2026-09-26 00:59:28.702 I  Kosmos[20670:2488082] [io.github.st-eez.kosmos:slide] slide frames: 50 callbacks, 3.20 ms in them, 0.35 ms at most, display 3
        """
    let lines = text.split(separator: "\n").compactMap { LogLine($0) }
    #expect(lines.map(\.category) == ["controller", "slide", "app", "slide", "slide", "slide"])
    let start = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 26, minute: 59, second: 28)))
    #expect(abs(lines[0].time - start.timeIntervalSince1970 - 0.257) < 1e-6)
    let facts = Facts(lines)
    #expect(facts.switches == [39.187] && facts.held == [4.5] && facts.failed == 0)
    #expect(facts.slid == 1 && facts.popped == 1 && facts.unlanded == 1 && facts.landed == [12.5] && facts.jumped == 1)
    #expect(facts.slowestFrame == 0.35 && facts.slowestWrite == 0.41)
    #expect(facts.stepped == [45, 49])
    #expect(abs(facts.completions[0] - (39.036 - 0.039 - 2.314 - 35.565 - 0.001 - 0.104)) < 1e-9)
    let more = """
        2026-09-26 00:59:28.703 I  Kosmos[20670:2488082] [io.github.st-eez.kosmos:slide] slide reads: 20, 12 of them 0.1 ms apart, over 30.0 ms
        2026-09-26 00:59:28.704 D  Kosmos[20670:2488082] [io.github.st-eez.kosmos:inventory] event spaceMembership(4242)
        """
    let extra = Facts(more.split(separator: "\n").compactMap { LogLine($0) })
    #expect(extra.readGaps == [1.5] && extra.memberships == 1)
}

@Test func theSummaryHasARowPerAction() {
    let (first, frames) = record(before: before, slide(after, from: [left, right]))
    let analysis = analyze(.slide, sent: sent, before: first, frames: frames, scene: scene)
    let records = (1...3).map { Record(number: $0, rep: $0, action: $0 == 2 ? "focus" : "resize", expect: .slide, sent: sent,
                                       settle: .settled, analysis: analysis) }
    let tables = summary(records).components(separatedBy: "\n\n").map { $0.split(separator: "\n") }
    #expect(tables.map(\.count) == [3, 3])
    #expect(tables[0][1].hasPrefix("resize  2 ") && tables[0][2].hasPrefix("focus   1 "))
    #expect(tables[1][0].hasPrefix("action  switch ms"))
}

@MainActor @Test func aRunWritesItsTablesAndPictures() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kosmos-bench-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    var replies: [String] = []
    let recorder = Recorder(directory: directory, display: "Test", refresh: refresh, real: false) { replies.append($0) }
    recorder.add(picture([], at: sent - 10))
    recorder.command("wallpaper", at: sent - 9)
    recorder.add(picture(before, at: sent - 5))
    recorder.command("step 1 1 slide resize", at: sent - 1)
    slide(after, from: [left, right]).forEach(recorder.add)
    recorder.command("sent 1 \(sent) \(sent + 0.003) 0", at: sent + 0.6)
    recorder.check(at: sent + 1)
    #expect(replies.prefix(2) == ["ok", "armed 1"])
    #expect(replies.count == 3 && replies[2].hasPrefix("done 1 20.00 ") && replies[2].hasSuffix(" 0 0 0 0 settled"), "\(replies)")

    // A switch with a blank frame between its states.
    recorder.command("step 2 1 instant alt-N", at: sent + 2)
    let switched = sent + 3
    recorder.add(picture([], at: switched + 0.02))
    recorder.add(picture(other, at: switched + 0.03))
    recorder.command("sent 2 \(switched) \(switched + 0.003) 0", at: switched + 0.04)
    recorder.check(at: switched + 1)
    #expect(replies.last == "done 2 20.00 2 0 0 0 1 settled")

    let stamp = DateFormatter()
    stamp.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    let log = "\(stamp.string(from: Date(timeIntervalSince1970: switched + 0.012))) Df Kosmos[1:2] [io.github.st-eez.kosmos:controller] switch to 0: 2 shown, 2 hidden "
        + "(0 stripped), before bridge 0.1 ms, bridge 5.0 ms (queued 0.1, sent 1.0, confirmed 1.0 by read, recovered 0.0, back 0.1), total 5.100 ms, confirmed\n"
    try log.write(to: directory.appendingPathComponent("kosmos.log"), atomically: true, encoding: .utf8)
    recorder.command("end", at: switched + 2)
    #expect(replies.last == "end" && recorder.finished)
    func read(_ file: String) throws -> String { try String(contentsOf: directory.appendingPathComponent(file), encoding: .utf8) }
    #expect(try read("steps.tsv").split(separator: "\n").count == 3)
    #expect(try read("events.tsv").contains("step\tframe") && read("events.tsv").contains("2\t0\t20.00\tflash\twallpaper"))
    #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("step-0002-frame-000-flash.png").path))
    #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("step-0002-before.png").path))
    #expect(try read("kosmos-steps.txt").contains("+12.0 ms  controller: switch to 0"))
    let table = try read("table.txt")
    #expect(table.contains("resize") && table.contains("alt-N") && table.contains("5.1/5.1"), "\(table)")
}

@MainActor @Test func aLineItCannotReadStopsTheRun() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kosmos-bench-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    var replies: [String] = []
    let recorder = Recorder(directory: directory, display: "Test", refresh: refresh, real: false) { replies.append($0) }
    recorder.command("sent 4 1 2 0", at: 0)
    #expect(replies == ["abort cannot read sent 4 1 2 0", "end"])
    #expect(recorder.finished)
}
