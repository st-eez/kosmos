// When each display frame of a slide shows, and whether a border's ring shows with it
// (docs/geometry.md, docs/borders.md).
//
//   kosmos-probe slide-sync [slides] [mode...]
//                                   Slides a red window of the probe's 240 points right in an
//                                   animation Space of the probe's, as Kosmos slides a window,
//                                   with a green ring around it, over a black window covering
//                                   the path, at the bottom left of the built-in display. A
//                                   display link steps the slide as Kosmos's does. A strip
//                                   across the path, recorded with ScreenCaptureKit, says which
//                                   callback's transform and which callback's ring each frame
//                                   shows. Each mode runs 6 slides by default, or the modes
//                                   named run alone:
//                                     layer     the ring's layer moved in a window covering the
//                                               display, both sent in the callback, as Kosmos
//                                               did before 2026-09-26
//                                     deferred  both sent a quarter of a refresh after the
//                                               vsync, as Kosmos sends them
//                                     flush     layer, with CATransaction.flush() after the ring
//                                     busy      layer, with the ring sent 0.5 ms after the
//                                               transform, as a callback's border work delays it
//                                     send300   both sent 0.3 ms after the link's timestamp
//                                     warm      layer, with the backdrop redrawn at each display
//                                               frame, so the display never idles
//                                     covered   layer, with the ring's window covering the
//                                               display before the slide starts
//                                     window    the ring's own window moved with AppKit
//                                     space     the ring's window in the slide's Space
//                                   Needs Screen Recording for the terminal, and exits rather
//                                   than ask. A crash leaves the Space, empty.
import AppKit
import CKosmos
import CoreMedia
import KosmosCore
@preconcurrency import ScreenCaptureKit
import Synchronization

private let distance: CGFloat = 240
private let ringWidth: CGFloat = 2

/// One display link callback: its times, and where it set the window and its ring to show,
/// as a fraction of the way.
private struct Tick {
    let slide: Int, index: Int
    let entry: Double, timestamp: Double, target: Double
    let progress: Double
}

/// One captured frame: its display time and where the window and its ring showed, as
/// fractions of the way, when they read.
private struct Seen: Sendable {
    let time: Double
    let window: Double?, ring: Double?
}

private enum RingMode: String, CaseIterable {
    case layer, deferred, flush, busy, send300, warm, covered, window, space
}

@MainActor func slideSync(slides: Int, modes: [String]) -> Never {
    let named = modes.map(RingMode.init(rawValue:))
    guard !named.contains(nil) else { usage() }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    guard let screen = NSScreen.screens.first(where: { CGDisplayIsBuiltin($0.displayID) != 0 }) else {
        print("error: the built-in display is off")
        exit(1)
    }
    // Asking would show a prompt.
    guard CGPreflightScreenCaptureAccess() else {
        print("error: this terminal has no Screen Recording permission")
        exit(1)
    }
    let rate = max(screen.maximumFramesPerSecond, 1), refresh = 1 / Double(rate), scale = screen.backingScaleFactor
    // Frames in CoreGraphics' coordinates, as Kosmos's are.
    let bounds = CGDisplayBounds(screen.displayID)
    let visible = appKitRect(screen.visibleFrame)
    let rest = CGRect(x: visible.minX + 40, y: visible.maxY - 140, width: 160, height: 100)
    let end = rest.offsetBy(dx: distance, dy: 0)
    let path = rest.union(end).insetBy(dx: -24, dy: -24)

    func plain(_ frame: CGRect, red: CGFloat) -> NSWindow {
        let window = NSWindow(contentRect: appKitRect(frame), styleMask: [.borderless], backing: .buffered, defer: false)
        window.backgroundColor = NSColor(srgbRed: red, green: 0, blue: 0, alpha: 1)
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.transient, .ignoresCycle]
        window.orderFrontRegardless()
        return window
    }
    let backdrop = plain(path, red: 0)
    let target = plain(rest, red: 1)
    let border = ProbeBorder()
    let green = CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)
    border.place(around: appKitRect(rest), radius: 0, width: ringWidth, color: green)
    border.window.order(.below, relativeTo: target.windowNumber)
    let space = kosmos_float_space_create(1)
    guard space != 0 else {
        print("error: no animation Space")
        exit(1)
    }

    // A strip 4 points tall across the path at the window's middle, in the display's points
    // from its top left.
    let strip = CGRect(x: path.minX - bounds.minX, y: rest.midY - bounds.minY - 2, width: path.width, height: 4)
    let capture = StripCapture(displayID: screen.displayID, strip: strip, scale: scale, rate: rate) { row, width in
        read(row, width: width, scale: CGFloat(width) / strip.width, from: path.minX, rest: rest)
    }
    capture.start()
    let started = Date()
    while capture.frames.withLock({ $0.isEmpty }), Date().timeIntervalSince(started) < 3 { pumpEvents(0.05) }
    guard !capture.frames.withLock({ $0.isEmpty }) else {
        print("error: the capture sent no frame\(capture.failure.withLock { $0.map { ": \($0)" } ?? "" })")
        kosmos_space_destroy(space)
        exit(1)
    }
    print(String(format: "built-in display at %d Hz, %.0fx; window %.0f by %.0f at (%.0f, %.0f), sliding %.0f points right over %.2f s",
                 rate, scale, rest.width, rest.height, rest.minX, rest.minY, distance, Slide.moveDuration))

    let chosen = named.isEmpty ? RingMode.allCases : named.compactMap { $0 }
    for mode in chosen {
        let run = SyncRun(mode, screen: screen, space: space, target: target, border: border, backdrop: backdrop, rest: rest, end: end,
                          rate: rate, green: green)
        pumpEvents(0.3)
        var slidesRun: [(added: Double, ended: Double)] = []
        for number in 1...slides {
            // A start at a random point of the refresh, as a command's is.
            pumpEvents(0.25 + Double.random(in: 0..<refresh))
            let added = run.begin(number)
            while run.sliding { pumpEvents(0.005) }
            pumpEvents(0.1)
            slidesRun.append((added, CACurrentMediaTime()))
            run.reset()
        }
        run.finish()
        pumpEvents(0.1)
        let frames = capture.frames.withLock { $0 }
        report(mode, ticks: run.ticks, slides: slidesRun, frames: frames, refresh: refresh, scale: scale)
    }
    capture.stop()
    kosmos_space_destroy(space)
    for window in [border.window, target, backdrop] { window.orderOut(nil) }
    exit(0)
}

/// Reads one row of BGRA pixels: the window's red from its left edge, and its ring's green
/// on either side where a whole ring's width shows, as fractions of the way.
private func read(_ row: UnsafeBufferPointer<UInt32>, width: Int, scale: CGFloat, from left: CGFloat, rest: CGRect) -> (Double?, Double?) {
    func channels(_ x: Int) -> (r: UInt32, g: UInt32, b: UInt32) {
        let pixel = row[x]
        return ((pixel >> 16) & 0xff, (pixel >> 8) & 0xff, pixel & 0xff)
    }
    func red(_ x: Int) -> Bool { let c = channels(x); return c.r > 160 && c.g < 100 && c.b < 100 }
    func green(_ x: Int) -> Bool { let c = channels(x); return c.g > 160 && c.r < 100 && c.b < 100 }
    guard let first = (0..<width).first(where: red), let last = (0..<width).last(where: red) else { return (nil, nil) }
    func fraction(_ pixel: CGFloat) -> Double { Double((left + pixel / scale - rest.minX) / distance) }
    let whole = Int((ringWidth * scale).rounded()) - 1
    var ring: Double?
    if let outer = (0..<first).first(where: green), (outer..<first).prefix(while: green).count >= whole {
        ring = fraction(CGFloat(outer) + ringWidth * scale)
    } else if let outer = (last + 1..<width).last(where: green), (last + 1...outer).reversed().prefix(while: green).count >= whole {
        ring = fraction(CGFloat(outer + 1) - (ringWidth + rest.width) * scale)
    }
    return (fraction(CGFloat(first)), ring)
}

@MainActor private final class SyncRun: NSObject {
    let mode: RingMode
    let screen: NSScreen
    let space: UInt64
    let target: NSWindow
    let border: ProbeBorder
    let backdrop: NSWindow
    let rest: CGRect, end: CGRect
    let rate: Int
    let green: CGColor
    private var slide: Slide?
    private var number = 0, index = 0
    private var link: CADisplayLink?
    private(set) var ticks: [Tick] = []
    private var dark = false

    init(_ mode: RingMode, screen: NSScreen, space: UInt64, target: NSWindow, border: ProbeBorder, backdrop: NSWindow, rest: CGRect,
         end: CGRect, rate: Int, green: CGColor) {
        (self.mode, self.screen, self.space, self.target, self.border, self.backdrop) = (mode, screen, space, target, border, backdrop)
        (self.rest, self.end, self.rate, self.green) = (rest, end, rate, green)
        super.init()
        if mode == .warm { startLink() }
        if mode == .covered { cover(at: rest) }
    }

    var sliding: Bool { slide != nil }

    private var windows: [UInt32] {
        mode == .space ? [UInt32(target.windowNumber), border.id] : [UInt32(target.windowNumber)]
    }

    private var movesLayer: Bool { mode != .window && mode != .space }

    /// As Kosmos starts a slide in one main actor turn: the window joins its Space, the link
    /// starts, and the border's window covers the display.
    func begin(_ number: Int) -> Double {
        (self.number, index) = (number, 0)
        var ids = windows
        kosmos_add_windows(space, &ids, ids.count, false)
        let now = CACurrentMediaTime()
        slide = .move(from: rest, to: end, at: now)
        if link == nil { startLink() }
        if movesLayer { cover(at: rest) }
        return now
    }

    /// The border's window over the display, its ring around `shown`.
    private func cover(at shown: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if border.window.frame != screen.frame { border.window.setFrame(screen.frame, display: false) }
        border.ring.frame = appKitRect(shown).insetBy(dx: -ringWidth, dy: -ringWidth).offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        CATransaction.commit()
    }

    private func startLink() {
        let link = screen.displayLink(target: self, selector: #selector(frame))
        let rate = Float(rate)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func frame(_ link: CADisplayLink) {
        if mode == .warm {
            dark.toggle()
            backdrop.backgroundColor = NSColor(srgbRed: dark ? 0 : 0.02, green: 0, blue: 0, alpha: 1)
        }
        guard slide != nil else { return }
        let (entry, timestamp, at) = (CACurrentMediaTime(), link.timestamp, link.targetTimestamp)
        guard mode == .deferred else { return step(link, entry: entry, timestamp: timestamp, at: at) }
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, timestamp + link.duration / 4 - CACurrentMediaTime())) {
            MainActor.assumeIsolated { self.step(link, entry: entry, timestamp: timestamp, at: at) }
        }
    }

    private func step(_ link: CADisplayLink, entry: Double, timestamp: Double, at: Double) {
        guard let slide else { return }
        let shown = slide.shown(at: at).frame
        if mode == .send300 {
            while CACurrentMediaTime() < timestamp + 0.0003 {}
        }
        kosmos_space_set_transform(space, Slide.transform(showing: shown, at: rest))
        if mode == .busy {
            while CACurrentMediaTime() < entry + 0.0005 {}
        }
        switch mode {
        case .window:
            border.window.setFrameOrigin(appKitRect(shown).insetBy(dx: -ringWidth, dy: -ringWidth).origin)
        case .space:
            break
        default:
            cover(at: shown)
            if mode == .flush { CATransaction.flush() }
        }
        index += 1
        let progress = Double((shown.minX - rest.minX) / distance)
        ticks.append(Tick(slide: number, index: index, entry: entry, timestamp: timestamp, target: at, progress: progress))
        guard slide.isOver(at: at) else { return }
        self.slide = nil
        if mode != .warm {
            link.invalidate()
            self.link = nil
        }
    }

    /// The window back at rest, out of the Space, and its ring around it.
    func reset() {
        kosmos_space_set_transform(space, .identity)
        var ids = windows
        kosmos_remove_windows(space, &ids, ids.count)
        if mode == .covered {
            cover(at: rest)
        } else {
            border.place(around: appKitRect(rest), radius: 0, width: ringWidth, color: green)
        }
    }

    func finish() {
        link?.invalidate()
        link = nil
        border.place(around: appKitRect(rest), radius: 0, width: ringWidth, color: green)
        backdrop.backgroundColor = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
    }
}

/// Matches each frame to the callback whose transform and ring it shows, where the callbacks'
/// fractions are far enough apart to tell, and prints what the frames say.
private func report(_ mode: RingMode, ticks: [Tick], slides: [(added: Double, ended: Double)], frames: [Seen], refresh: Double,
                    scale: CGFloat) {
    let pixel = 1 / (Double(distance) * Double(scale))
    /// The callback whose fraction the read shows: within 2.5 pixels, as the window's red edge
    /// reads up to 2 pixels left of where its transform puts it, with no other callback's
    /// within 4 unless it set the same fraction, when the first of them counts.
    func match(_ read: Double?, _ ticks: [Tick]) -> Tick? {
        guard let read else { return nil }
        let near = ticks.filter { abs($0.progress - read) <= 4 * pixel }
        guard let best = near.min(by: { abs($0.progress - read) < abs($1.progress - read) }), abs(best.progress - read) <= 2.5 * pixel,
              near.allSatisfy({ abs($0.progress - best.progress) < 0.1 * pixel }) else { return nil }
        return near.min { $0.index < $1.index }
    }
    func median(_ values: [Double]) -> String {
        values.isEmpty ? "-" : String(format: "%.2f", percentile(values, 0.5))
    }
    var latency: [Int: [Double]] = [:]
    var lag: [Int: Int] = [:]
    var holds = 0, firsts = 0, captured = 0
    var gaps: [Double] = []
    var lines: [String] = []
    for (offset, span) in slides.enumerated() {
        let number = offset + 1
        let own = ticks.filter { $0.slide == number }
        let seen = frames.filter { $0.time >= span.added && $0.time <= span.ended }
        captured += seen.count
        gaps += zip(seen, seen.dropFirst()).map { ($1.time - $0.time) / refresh }
        var shownAt: [Int: Double] = [:]
        for frame in seen {
            let window = match(frame.window, own), ring = match(frame.ring, own)
            if let window, shownAt[window.index] == nil { shownAt[window.index] = frame.time }
            if let window, let ring { lag[window.index - ring.index, default: 0] += 1 }
        }
        for tick in own {
            guard let time = shownAt[tick.index] else { continue }
            latency[min(tick.index, 4), default: []].append((time - tick.target) / refresh)
        }
        // The first frame that moved the window, and the next that moved it again.
        let moved = seen.filter { ($0.window ?? 0) > pixel }
        if let first = moved.first, let next = moved.dropFirst().first(where: { abs(($0.window ?? 0) - (first.window ?? 0)) > pixel }) {
            firsts += 1
            if next.time - first.time > 1.5 * refresh { holds += 1 }
        }
        // Milliseconds from the first callback's timestamp.
        let origin = own.first?.timestamp ?? span.added
        func ms(_ time: Double) -> String { String(format: "%.1f", (time - origin) * 1000) }
        let head = own.prefix(3).map { tick in
            "\(ms(tick.timestamp))/\(ms(tick.entry))/\(ms(tick.target))/\(shownAt[tick.index].map(ms) ?? "-")"
        }
        // The first frames from the first callback on: which callback's window and ring each
        // shows, 0 for none yet and ? for one the fractions cannot tell.
        let early = seen.filter { $0.time >= origin }.prefix(6).map { frame in
            func name(_ read: Double?) -> String {
                guard let read else { return "-" }
                if read < pixel { return "0" }
                if let tick = match(read, own) { return "\(tick.index)" }
                guard let near = own.min(by: { abs($0.progress - read) < abs($1.progress - read) }) else { return "?" }
                return String(format: "?%d%+.1f", near.index, (read - near.progress) / pixel)
            }
            return "\(ms(frame.time)) w\(name(frame.window)) r\(name(frame.ring))"
        }
        lines.append("  slide \(number): start \(ms(span.added)), callbacks 1 to 3 \(head.joined(separator: ", ")); frames \(early.joined(separator: ", "))")
    }
    let all = ticks.filter { $0.index > 1 }
    print("\(mode.rawValue): \(slides.count) slides, \(ticks.count) callbacks, \(captured) frames captured, "
          + "\(median(gaps)) refreshes apart at the median")
    print("  callback after its timestamp, ms: first \(median(ticks.filter { $0.index == 1 }.map { ($0.entry - $0.timestamp) * 1000 })), "
          + "later \(median(all.map { ($0.entry - $0.timestamp) * 1000 })); target after timestamp, ms: first "
          + "\(median(ticks.filter { $0.index == 1 }.map { ($0.target - $0.timestamp) * 1000 })), later "
          + "\(median(all.map { ($0.target - $0.timestamp) * 1000 }))")
    let byIndex = [1, 2, 3, 4].map { index in
        "\(index == 4 ? "later" : "\(index)") \(median(latency[index] ?? [])) (\(latency[index]?.count ?? 0))"
    }
    print("  window shown after its callback's target, refreshes at the median (frames): \(byIndex.joined(separator: ", "))")
    print("  first move then nothing new for a refresh or more: \(holds) of \(firsts) slides")
    let lags = lag.keys.sorted().map { "\($0 == 0 ? "with its window" : $0 > 0 ? "\($0) behind" : "\(-$0) ahead") \(lag[$0]!)" }
    print("  ring against its window, frames: \(lags.isEmpty ? "none read" : lags.joined(separator: ", "))")
    print("  per slide, ms from the first callback's timestamp: the start, and each callback's timestamp/entry/target/first frame showing it:")
    lines.forEach { print($0) }
}

/// A ScreenCaptureKit stream of a strip of one display, each frame read at once and let go.
private final class StripCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let frames = Mutex<[Seen]>([])
    let failure = Mutex<String?>(nil)
    private let displayID: CGDirectDisplayID
    private let configuration = SCStreamConfiguration()
    private let queue = DispatchQueue(label: "kosmos-probe.slide-sync", qos: .userInteractive)
    private let read: @Sendable (UnsafeBufferPointer<UInt32>, Int) -> (Double?, Double?)
    private var stream: SCStream?
    private let ticks: Double

    init(displayID: CGDirectDisplayID, strip: CGRect, scale: CGFloat, rate: Int,
         read: @escaping @Sendable (UnsafeBufferPointer<UInt32>, Int) -> (Double?, Double?)) {
        self.displayID = displayID
        self.read = read
        var timebase = mach_timebase_info()
        mach_timebase_info(&timebase)
        ticks = Double(timebase.numer) / Double(timebase.denom) / 1e9
        configuration.sourceRect = strip
        configuration.width = Int(strip.width * scale)
        configuration.height = Int(strip.height * scale)
        // Half a refresh, so a refresh that comes a little early is not dropped.
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(2 * rate))
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.showsCursor = false
        configuration.queueDepth = 8
        super.init()
    }

    func start() {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
            guard let display = content?.displays.first(where: { $0.displayID == self.displayID }) else {
                self.failure.withLock { $0 = "no shareable built-in display: \(error.map { "\($0)" } ?? "not listed")" }
                return
            }
            let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: self.configuration, delegate: self)
            do {
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue)
            } catch {
                self.failure.withLock { $0 = "\(error)" }
                return
            }
            self.stream = stream
            stream.startCapture { error in if let error { self.failure.withLock { $0 = "\(error)" } } }
        }
    }

    func stop() {
        let done = DispatchSemaphore(value: 0)
        stream?.stopCapture { _ in done.signal() }
        _ = done.wait(timeout: .now() + 2)
    }

    /// The display time is mach absolute time, the clock of CACurrentMediaTime and the display
    /// link's timestamps.
    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, buffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first, let status = (info[.status] as? Int).flatMap(SCFrameStatus.init),
              status == .complete || status == .started,
              let displayTime = info[.displayTime] as? UInt64, let pixels = CMSampleBufferGetImageBuffer(buffer) else { return }
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixels) else { return }
        let width = CVPixelBufferGetWidth(pixels), middle = CVPixelBufferGetHeight(pixels) / 2
        let row = UnsafeBufferPointer(start: (base + middle * CVPixelBufferGetBytesPerRow(pixels)).assumingMemoryBound(to: UInt32.self),
                                      count: width)
        let (window, ring) = read(row, width)
        frames.withLock { $0.append(Seen(time: Double(displayTime) * ticks, window: window, ring: ring)) }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        failure.withLock { $0 = "the stream stopped: \(error)" }
    }
}
