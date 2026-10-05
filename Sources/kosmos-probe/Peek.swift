// Whether a concealed window can show on its display without the user seeing it, long enough
// for a screenshot of it to be current, then go back into the holding Space (docs/hiding.md).
//
//   kosmos-probe peek [trials] [variant...] [cua]
//                                   A child app's titled panel at the bottom left of the
//                                   built-in display draws the tenths of a second since its
//                                   start as 16 black and white cells, and stops drawing while
//                                   its occlusion state is not visible, as Chromium does. It
//                                   logs each draw and every notification of its window. It
//                                   starts off every display, so the user never sees it, and
//                                   lives in a holding Space of the probe's own, made as
//                                   Kosmos makes one, keeping the built-in display's current
//                                   Space as a concealed window keeps its own. Each trial of a
//                                   variant moves it from the holding Space into a peek Space
//                                   of the probe's, captures it with ScreenCaptureKit until the
//                                   capture shows the current count, once with `screencapture
//                                   -l`, and the screen around it, then moves it back. A peek
//                                   before each variant's trials stops the variant when the
//                                   screen shows the panel. Each variant runs 5 trials by
//                                   default, or the variants named run alone:
//                                     clear    an animation Space, level 1, at alpha 0
//                                     faint    the same at alpha 0.01
//                                     clipped  faint, with the Space's shape set to one point
//                                              at the panel's top left
//                                     below    a Space under the desktop Space at alpha 1,
//                                              the panel stripped of its ordinary Space
//                                     tiny     an animation Space at alpha 1 scaled to show
//                                              the panel at 1/400 of its size
//                                     covered  an animation Space at alpha 1 under a window
//                                              of the probe's, not opaque, that shows a
//                                              capture of the screen taken before the peek
//                                   With `cua`, a CuaDriver daemon already running takes one
//                                   screenshot of the panel concealed and one in the first
//                                   trial of each variant. Hit tests read WindowServer and post
//                                   no event. Needs Screen Recording for the terminal. Ctrl-C
//                                   conceals the panel, quits its app and destroys the Spaces.
import AppKit
import CKosmos
import CKosmosSweep
import KosmosSkyLight
@preconcurrency import ScreenCaptureKit
import Synchronization

private let peekSize = CGSize(width: 200, height: 120)
private let peekBits = 16
private let peekTick = 100.0   // ms per count

private enum PeekVariant: String, CaseIterable {
    case clear, faint, clipped, below, tiny, covered

    var alpha: Float {
        switch self {
        case .clear: 0
        case .faint, .clipped: 0.01
        case .below, .tiny, .covered: 1
        }
    }
}

/// How far the captures of the screen reach past the panel's frame, for its shadow.
private let peekMargin: CGFloat = 40

/// The panel's frame in a capture of the area around it.
private func peekInside(_ area: Pixels) -> CGRect {
    let scale = CGFloat(area.width) / (peekSize.width + 2 * peekMargin)
    return CGRect(x: peekMargin * scale, y: peekMargin * scale, width: peekSize.width * scale, height: peekSize.height * scale)
}

/// A window of the probe's own over the area around the panel, in a Space at level 2, that
/// shows a capture of the area taken before the peek. It is not opaque, so WindowServer does
/// not count the panel under it as covered.
@MainActor private final class PeekCover {
    private let window: NSWindow
    private let space: UInt64

    init?(around rest: CGRect, cleanup: PeekCleanup) {
        space = kosmos_float_space_create(2)
        guard space != 0 else { return nil }
        cleanup.add(space)
        kosmos_space_set_alpha(space, 0)
        window = NSWindow(contentRect: appKitRect(rest.insetBy(dx: -peekMargin, dy: -peekMargin)), styleMask: [.borderless],
                          backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.transient, .ignoresCycle]
        window.contentView!.wantsLayer = true
        window.contentView!.layer!.contentsGravity = .resize
        window.orderFrontRegardless()
        var ids = [UInt32(window.windowNumber)]
        kosmos_add_windows(space, &ids, 1, true)
        _ = kosmos_barrier(space)
    }

    func show(_ image: CGImage) {
        window.contentView!.layer!.contents = image
        CATransaction.flush()
        pumpEvents(0.03)
        kosmos_space_set_alpha(space, 1)
        _ = kosmos_barrier(space)
    }

    func hide() {
        kosmos_space_set_alpha(space, 0)
        _ = kosmos_barrier(space)
    }
}

/// Where the panel rests, in CoreGraphics' coordinates.
@MainActor private func peekRest() -> CGRect {
    let visible = appKitRect(builtInScreen().visibleFrame)
    return CGRect(x: visible.minX + 40, y: visible.maxY - 40 - peekSize.height, width: peekSize.width, height: peekSize.height)
}

/// A white cell, the count's bits from the highest, then a black cell, along the bottom.
private final class CountView: NSView {
    var count = 0
    var drew: ((Int) -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1).setFill()
        bounds.fill()
        let cell = (bounds.width - 20) / CGFloat(peekBits + 2)
        for index in 0...(peekBits + 1) {
            let on = index == 0 || (index <= peekBits && (count >> (peekBits - index)) & 1 == 1)
            (on ? NSColor.white : NSColor.black).setFill()
            NSRect(x: 10 + CGFloat(index) * cell, y: 10, width: cell, height: 30).fill()
        }
        NSString(string: "\(count)").draw(at: NSPoint(x: 10, y: 50), withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 24, weight: .bold)])
        drew?(count)
    }
}

/// A panel that keeps the frame it is given, off every display too.
private final class PeekPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// The panel, in an app never activated. A click neither activates the app nor keys the panel.
/// Prints its id and its start uptime, then a line per draw and per notification of the panel.
/// `rest` on its standard input moves it to its rest; it runs until that closes.
@MainActor func peekWindow() -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let start = uptime()
    let panel = PeekPanel(contentRect: .zero, styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.title = "kosmos-probe peek"
    panel.becomesKeyOnlyIfNeeded = true
    panel.hidesOnDeactivate = false
    panel.animationBehavior = .none
    panel.isReleasedWhenClosed = false
    let view = CountView()
    panel.contentView = view
    panel.setFrame(NSRect(x: -10000, y: -10000, width: peekSize.width, height: peekSize.height), display: false)
    func log(_ text: String) { print(String(format: "%.3f ", uptime()) + text) }
    view.drew = { log("draw \($0)") }
    func current() -> Int { Int((uptime() - start) / peekTick) }
    NotificationCenter.default.addObserver(forName: nil, object: panel, queue: .main) { note in
        let name = note.name
        MainActor.assumeIsolated {
            let visible = panel.occlusionState.contains(.visible)
            log("note \(name.rawValue) visible \(visible) active-space \(panel.isOnActiveSpace) screen \(panel.screen?.localizedName ?? "none")")
            if visible && name == NSWindow.didChangeOcclusionStateNotification {
                view.count = current()
                view.display()
            }
        }
    }
    for name in [NSApplication.didChangeOcclusionStateNotification, NSApplication.didBecomeActiveNotification] {
        NotificationCenter.default.addObserver(forName: name, object: app, queue: .main) { _ in
            MainActor.assumeIsolated { log("app \(name.rawValue) visible \(app.occlusionState.contains(.visible))") }
        }
    }
    let timer = Timer(timeInterval: 0.01, repeats: true) { _ in
        MainActor.assumeIsolated {
            guard panel.occlusionState.contains(.visible), current() != view.count else { return }
            view.count = current()
            view.needsDisplay = true
        }
    }
    RunLoop.main.add(timer, forMode: .common)
    print("\(panel.windowNumber) \(String(format: "%.3f", start))")
    panel.orderFrontRegardless()
    log("start visible \(panel.occlusionState.contains(.visible))")
    Thread.detachNewThread {
        while let line = readLine() {
            guard line == "rest" else { continue }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    panel.setFrame(appKitRect(peekRest()), display: true)
                    log("rest \(panel.frame)")
                }
            }
        }
        exit(0)
    }
    app.run()
    exit(0)
}

/// What the panel's app logged, by uptime.
private struct StubLine: Sendable {
    let at: Double
    let kind: Substring
    let text: Substring
}

private final class StubLog: Sendable {
    let lines = Mutex<[StubLine]>([])
}

private enum Shot: CustomStringConvertible {
    case failed(String)
    /// Every pixel transparent.
    case blank
    case unreadable(opacity: Int)
    /// `opacity`: the image's most opaque pixel, 255 for an opaque one.
    case count(Int, opacity: Int)

    var description: String {
        switch self {
        case .failed(let why): "failed: \(why)"
        case .blank: "blank"
        case .unreadable(let opacity): "unreadable at opacity \(opacity)"
        case .count(let count, let opacity): "count \(count)\(opacity == 255 ? "" : " at opacity \(opacity)")"
        }
    }
}

/// An image's pixels as sRGB bytes, 4 to a pixel.
private struct Pixels {
    let width: Int, height: Int
    let bytes: [UInt8]
    let image: CGImage

    init(_ image: CGImage) {
        self.image = image
        (width, height) = (image.width, image.height)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                    bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        self.bytes = bytes
    }

    /// Light or dark at a point from the top left, in pixels, with the alpha taken out.
    func light(_ x: Int, _ y: Int) -> Bool {
        let i = (min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1)) * 4
        return 2 * (Int(bytes[i]) + Int(bytes[i + 1]) + Int(bytes[i + 2])) > 3 * Int(bytes[i + 3])
    }

    /// The count the panel drew, from a capture of the panel alone at any scale.
    var count: Shot {
        let (x, y) = (Double(width) / peekSize.width, Double(height) / peekSize.height)
        let cell = (peekSize.width - 20) / CGFloat(peekBits + 2)
        let row = Int(Double(peekSize.height - 25) * y)
        let opacity = Int(stride(from: 3, to: bytes.count, by: 4).map { bytes[$0] }.max() ?? 0)
        guard opacity > 0 else { return .blank }
        let bits = (0...(peekBits + 1)).map { light(Int((10 + (CGFloat($0) + 0.5) * cell) * x), row) }
        guard bits.first == true, bits.last == false else { return .unreadable(opacity: opacity) }
        return .count(bits.dropFirst().dropLast().reduce(0) { $0 << 1 | ($1 ? 1 : 0) }, opacity: opacity)
    }

    /// Pixels of the panel's magenta.
    var magenta: Int {
        stride(from: 0, to: bytes.count, by: 4).filter { bytes[$0] > 200 && bytes[$0 + 1] < 80 && bytes[$0 + 2] > 200 }.count
    }
}

/// How two captures of the same area differ, inside and outside a rectangle in pixels.
private struct Difference: CustomStringConvertible {
    var inside = (changed: 0, over2: 0, most: 0), outside = (changed: 0, over2: 0, most: 0)

    init(_ a: Pixels, _ b: Pixels, inside rect: CGRect) {
        guard a.width == b.width, a.height == b.height else { return }
        for y in 0..<a.height {
            for x in 0..<a.width {
                let i = (y * a.width + x) * 4
                let delta = (0..<3).map { abs(Int(a.bytes[i + $0]) - Int(b.bytes[i + $0])) }.max()!
                guard delta > 0 else { continue }
                if rect.contains(CGPoint(x: x, y: y)) {
                    inside = (inside.changed + 1, inside.over2 + (delta > 2 ? 1 : 0), max(inside.most, delta))
                } else {
                    outside = (outside.changed + 1, outside.over2 + (delta > 2 ? 1 : 0), max(outside.most, delta))
                }
            }
        }
    }

    var description: String {
        "inside \(inside.changed) px changed, \(inside.over2) by more than 2, most \(inside.most); "
            + "outside \(outside.changed), \(outside.over2), most \(outside.most)"
    }
}

/// Runs `body` with a completion handler and waits for it.
private func waiting<T>(_ body: (@escaping @Sendable (T) -> Void) -> Void) -> T {
    let done = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var result: T?
    body { value in
        result = value
        done.signal()
    }
    done.wait()
    return result!
}

/// A capture of the window alone, as an agent's screenshot tool takes it.
private func captureWindow(_ window: UInt32, save path: String? = nil) -> (Shot, Double) {
    let start = uptime()
    let content = waiting { done in
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { content, _ in done(content) }
    }
    guard let target = content?.windows.first(where: { $0.windowID == window }) else { return (.failed("not shareable"), uptime() - start) }
    let filter = SCContentFilter(desktopIndependentWindow: target)
    let configuration = SCStreamConfiguration()
    // The panel's size: the window list's frame follows a Space's scale.
    configuration.width = Int(peekSize.width * CGFloat(filter.pointPixelScale))
    configuration.height = Int(peekSize.height * CGFloat(filter.pointPixelScale))
    configuration.showsCursor = false
    configuration.ignoreShadowsSingleWindow = true
    let (image, error): (CGImage?, String?) = waiting { done in
        SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, error in
            done((image, error.map { $0.localizedDescription }))
        }
    }
    let took = uptime() - start
    guard let image else { return (.failed(error ?? "no image"), took) }
    if let path, let file = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil) {
        CGImageDestinationAddImage(file, image, nil)
        CGImageDestinationFinalize(file)
    }
    return (Pixels(image).count, took)
}

/// What the screen shows around `rect`, `peekMargin` out, on the built-in display.
@MainActor private func captureArea(_ rect: CGRect) -> Pixels? {
    let screen = builtInScreen(), bounds = CGDisplayBounds(screen.displayID)
    let content = waiting { done in
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, _ in done(content) }
    }
    guard let display = content?.displays.first(where: { $0.displayID == screen.displayID }) else { return nil }
    let configuration = SCStreamConfiguration()
    configuration.sourceRect = rect.insetBy(dx: -peekMargin, dy: -peekMargin).offsetBy(dx: -bounds.minX, dy: -bounds.minY)
    configuration.width = Int(configuration.sourceRect.width * screen.backingScaleFactor)
    configuration.height = Int(configuration.sourceRect.height * screen.backingScaleFactor)
    configuration.colorSpaceName = CGColorSpace.sRGB
    configuration.showsCursor = false
    let filter = SCContentFilter(display: display, excludingWindows: [])
    let image: CGImage? = waiting { done in
        SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, _ in done(image) }
    }
    return image.map(Pixels.init)
}

/// Runs a command and returns its exit status and combined output.
private func run(_ path: String, _ arguments: [String]) -> (Int32, String) {
    let process = Process(), pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    process.standardOutput = pipe
    process.standardError = pipe
    try! process.run()
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
}

/// A PNG's count, or why there is none.
private func shot(fromFile path: String, status: Int32, output: String) -> Shot {
    guard status == 0, let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        return .failed("status \(status): \(output.prefix(160))")
    }
    try? FileManager.default.removeItem(atPath: path)
    return Pixels(image).count
}

private func screencapture(_ window: UInt32) -> (Shot, Double) {
    let start = uptime(), path = NSTemporaryDirectory() + "kosmos-probe-peek.png"
    let (status, output) = run("/usr/sbin/screencapture", ["-x", "-o", "-l", "\(window)", path])
    return (shot(fromFile: path, status: status, output: output), uptime() - start)
}

/// A screenshot through a running CuaDriver daemon, as an agent takes one.
private func cuaShot(pid: pid_t, window: UInt32) -> (Shot, Double) {
    let start = uptime(), path = NSTemporaryDirectory() + "kosmos-probe-peek-cua.png"
    try? FileManager.default.removeItem(atPath: path)
    let arguments = #"{"pid":\#(pid),"window_id":\#(window),"include_accessibility_tree":false,"screenshot_out_file":"\#(path)"}"#
    let (status, output) = run(NSHomeDirectory() + "/.local/bin/cua-driver", ["call", "get_window_state", arguments])
    let exists = FileManager.default.fileExists(atPath: path)
    return (shot(fromFile: path, status: exists ? 0 : max(status, 1), output: output), uptime() - start)
}

/// The probe's Spaces and the panel's app, for the cleanup at the end and at Ctrl-C.
private final class PeekCleanup: @unchecked Sendable {
    private let lock = NSLock()
    private var spaces: [UInt64] = [], done = false
    private let holding: UInt64, window: UInt32, child: Child

    init(holding: UInt64, window: UInt32, child: Child) {
        (self.holding, self.window, self.child) = (holding, window, child)
        spaces = [holding]
    }

    func add(_ space: UInt64) { lock.withLock { spaces.append(space) } }

    /// Conceals the panel, takes it out of every peek Space, quits its app, then destroys the
    /// Spaces.
    func run() {
        let spaces = lock.withLock { () -> [UInt64]? in
            guard !done else { return nil }
            done = true
            return self.spaces
        }
        guard let spaces else { return }
        var ids = [window]
        kosmos_add_windows(holding, &ids, 1, false)
        for space in spaces where space != holding { kosmos_remove_windows(space, &ids, 1) }
        _ = kosmos_barrier(holding)
        child.quit()
        spaces.forEach(kosmos_space_destroy)
        _ = kosmos_barrier(holding)
    }
}

private struct PeekTrial {
    var start = 0.0, landed: Double?
    /// ms to capture the area and show it over the panel's rest, before the peek.
    var cover: Double?
    var captures: [(at: Double, took: Double, shot: Shot, lag: Int?)] = []
    var current: Double?
    var early: (Shot, Double)?, late: (Shot, Double)?, cua: (Shot, Double)?
    var visible: Double?, draw: Double?
    var notes: [String] = []
    var end = 0.0, concealed: Double?, hidden: Double?, lastDraw: Double?
    var shown: Difference?, noise: Difference?
    var hit: (before: Int, during: Int, after: Int) = (0, 0, 0)
    var listed: String = ""
}

@MainActor func peek(trials count: Int, variants names: [String], cua: Bool) -> Never {
    let named = names.map(PeekVariant.init(rawValue:))
    guard !named.contains(nil) else { usage() }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    guard NSScreen.screens.contains(where: { CGDisplayIsBuiltin($0.displayID) != 0 }) else {
        print("error: the built-in display is off")
        exit(1)
    }
    guard CGPreflightScreenCaptureAccess() else {
        print("error: this terminal has no Screen Recording permission")
        exit(1)
    }
    let child = Child(["peek-window"])
    let header = child.line().split(separator: " ")
    guard header.count == 2, let window = UInt32(header[0]), let born = Double(header[1]) else { print("error: no panel"); exit(1) }
    let lines = StubLog()
    child.onLines { line in
        let fields = line.split(separator: " ", maxSplits: 2)
        guard fields.count >= 2, let at = Double(fields[0]) else { return }
        lines.lines.withLock { $0.append(StubLine(at: at, kind: fields[1], text: fields.count > 2 ? fields[2] : "")) }
    }
    func logged(after time: Double, _ kind: Substring) -> [StubLine] {
        lines.lines.withLock { $0.filter { $0.at >= time && $0.kind == kind } }
    }
    func occlusion(after time: Double, visible: Bool) -> Double? {
        logged(after: time, "note").first {
            $0.text.hasPrefix(NSWindow.didChangeOcclusionStateNotification.rawValue) && $0.text.contains("visible \(visible)")
        }?.at
    }
    func expected(at time: Double) -> Int { Int((time - born) / peekTick) }

    let holding = kosmos_holding_create()
    guard holding != 0 else { print("error: no holding Space"); child.terminate(); exit(1) }
    let cleanup = PeekCleanup(holding: holding, window: window, child: child)
    signal(SIGINT, SIG_IGN)
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    // Sendable, so it runs off the main actor while the main thread waits on a capture.
    interrupt.setEventHandler { @Sendable in
        cleanup.run()
        print("interrupted; cleaned up")
        exit(130)
    }
    interrupt.resume()
    var ids = [window]
    kosmos_add_windows(holding, &ids, 1, false)
    _ = kosmos_barrier(holding)
    child.send("rest")
    let rest = peekRest()
    var waited = 0
    while logged(after: 0, "rest").isEmpty && waited < 100 { pumpEvents(0.01); waited += 1 }

    let displays = Displays.current(), screen = builtInScreen()
    let ordinary = displays.ordinarySpace(on: screen.displayID, original: nil) ?? 0
    // Created off every display, the panel has no ordinary Space; a window Kosmos conceals
    // keeps its own, and an exclusive add leaves it in the holding Space (kosmos-probe reveal).
    let created = SkyLight.spaces(of: window) ?? []
    kosmos_add_windows(ordinary, &ids, 1, true)
    _ = kosmos_barrier(holding)
    var ordinaryLevel: Int32 = 0
    let levelRead = kosmos_peek_space_level(ordinary, &ordinaryLevel)
    print(String(format: "panel %d of pid %d, %.0f by %.0f at (%.0f, %.0f) on the built-in display; holding Space %llu, in it %@; "
                 + "its ordinary Spaces %@, then %@ after an exclusive add; the built-in display's current Space %llu at level %@",
                 window, child.pid, rest.width, rest.height, rest.minX, rest.minY, holding, "\(inSpace(window, holding))",
                 "\(created)", "\(SkyLight.spaces(of: window) ?? [])", ordinary, levelRead ? "\(ordinaryLevel)" : "unread"))

    // Concealed: does the panel stop drawing, and what does a capture give?
    pumpEvents(3)
    let all = lines.lines.withLock { $0 }
    let occlusions = all.filter { $0.text.hasPrefix(NSWindow.didChangeOcclusionStateNotification.rawValue) }
    print("concealed for 3 s: visible at its start \(all.first { $0.kind == "start" }?.text.contains("true") == true), "
          + "occlusion changes \(occlusions.map { $0.text.contains("visible true") ? "visible" : "hidden" }), "
          + "\(all.filter { $0.kind == "draw" }.count) draws, the last \(all.last { $0.kind == "draw" }.map { String(format: "%.0f ms before now", uptime() - $0.at) } ?? "never")")
    let (held, heldTook) = captureWindow(window)
    let (heldScreencapture, heldScreencaptureTook) = screencapture(window)
    print(String(format: "  ScreenCaptureKit %@ in %.0f ms; screencapture -l %@ in %.0f ms", "\(held)", heldTook, "\(heldScreencapture)", heldScreencaptureTook))
    if cua {
        let (shot, took) = cuaShot(pid: child.pid, window: window)
        print(String(format: "  cua-driver %@ in %.0f ms", "\(shot)", took))
    }
    let center = NSPoint(x: rest.midX, y: NSScreen.screens[0].frame.height - rest.midY)
    func hit() -> Int { NSWindow.windowNumber(at: center, belowWindowWithWindowNumber: 0) }

    let chosen = named.isEmpty ? PeekVariant.allCases : named.compactMap { $0 }
    for variant in chosen {
        let space = kosmos_float_space_create(variant == .below ? ordinaryLevel - 1 : 1)
        guard space != 0 else { print("\(variant.rawValue): no Space"); continue }
        cleanup.add(space)
        // Transparent before the panel joins it, as a pop's Space.
        kosmos_space_set_alpha(space, variant == .below || variant == .covered ? 0 : variant.alpha)
        if variant == .clipped {
            var shape = CGRect.null
            let set = kosmos_peek_space_set_shape(space, CGRect(origin: rest.origin, size: CGSize(width: 1, height: 1)))
            let read = kosmos_peek_space_shape(space, &shape)
            print("\(variant.rawValue): shape set \(set), read \(read ? "\(shape)" : "failed")")
        }
        if variant == .tiny { kosmos_space_set_transform(space, CGAffineTransform(scaleX: 400, y: 400)) }
        let cover = variant == .covered ? PeekCover(around: rest, cleanup: cleanup) : nil
        if variant == .covered && cover == nil { print("\(variant.rawValue): no cover"); continue }
        /// Out of the holding Space into the peek Space, or back; the uptime it landed.
        func move(peek: Bool) -> Double? {
            let start = uptime()
            if peek {
                kosmos_add_windows(space, &ids, 1, variant == .below)
                kosmos_remove_windows(holding, &ids, 1)
            } else {
                kosmos_add_windows(holding, &ids, 1, false)
                kosmos_remove_windows(space, &ids, 1)
            }
            while uptime() - start < 10 && inSpace(window, holding) == peek { usleep(100) }
            if inSpace(window, holding) == peek { _ = kosmos_barrier(holding) }
            return inSpace(window, holding) == peek ? nil : uptime()
        }
        // A peek before the trials, read back at once. Under the desktop picture, and under
        // the cover, only then does the Space go to alpha 1, and back to alpha 0 once the
        // screen shows the panel.
        let first = captureArea(rest)
        if let first { cover?.show(first.image) }
        _ = move(peek: true)
        var seen = captureArea(rest)
        if variant == .below && seen?.magenta == 0 {
            let order = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? [])
            let own = order.firstIndex { $0[kCGWindowNumber as String] as? UInt32 == window }
            let pictures = order.indices.filter { index in
                let bounds = (order[index][kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) }
                return order[index][kCGWindowName as String] as? String == "Wallpaper" && bounds?.contains(rest) == true
            }
            print("\(variant.rawValue): on screen at index \(own.map(String.init) ?? "none") of \(order.count), "
                  + "desktop pictures over its rest at \(pictures)")
            seen = nil
            if let own, pictures.contains(where: { $0 < own }) {
                kosmos_space_set_alpha(space, 1)
                seen = captureArea(rest)
            }
        }
        if variant == .covered && seen != nil {
            kosmos_space_set_alpha(space, 1)
            seen = captureArea(rest)
        }
        // The scaled panel can show as a pixel or two.
        let magenta = seen?.magenta ?? -1, shows = magenta < 0 || magenta > (variant == .tiny ? 4 : 0)
        if shows && variant.alpha == 1 { kosmos_space_set_alpha(space, 0) }
        _ = move(peek: false)
        cover?.hide()
        print("\(variant.rawValue): the screen showed \(magenta) of its pixels in a peek before the trials"
              + (first != nil && seen != nil ? "; the area against before it: \(Difference(first!, seen!, inside: peekInside(first!)))" : ""))
        guard !shows else { continue }
        pumpEvents(1.5)
        var trials: [PeekTrial] = []
        for index in 1...count {
            var trial = PeekTrial()
            let coverStart = uptime()
            let before = captureArea(rest)
            if let before, let cover {
                cover.show(before.image)
                trial.cover = uptime() - coverStart
            }
            trial.hit.before = hit()
            trial.start = uptime()
            trial.landed = move(peek: true)
            while trial.current == nil && uptime() - trial.start < 3000 {
                let at = uptime()
                let (shot, took) = captureWindow(window, save: index == 1 && trial.captures.count < 2
                                                 ? NSTemporaryDirectory() + "kosmos-probe-peek-\(variant.rawValue)-\(trial.captures.count).png" : nil)
                var lag: Int?
                if case .count(let shown, _) = shot {
                    lag = expected(at: at) - shown
                    if lag! <= 1 { trial.current = at + took - trial.start }
                }
                trial.captures.append((at - trial.start, took, shot, lag))
                if trial.captures.count == 1 { trial.early = screencapture(window) }
            }
            trial.late = screencapture(window)
            if cua && index == 1 { trial.cua = cuaShot(pid: child.pid, window: window) }
            trial.hit.during = hit()
            let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], window) as? [[String: Any]])?.first
            trial.listed = "on screen \((info?[kCGWindowIsOnscreen as String] as? Bool) ?? false), "
                + "bounds \((info?[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) }.map { "\($0)" } ?? "none")"
            let during = captureArea(rest)
            trial.end = uptime()
            trial.concealed = move(peek: false).map { $0 - trial.end }
            cover?.hide()
            pumpEvents(1.5)
            let after = captureArea(rest)
            trial.hit.after = hit()
            trial.visible = occlusion(after: trial.start, visible: true).map { $0 - trial.start }
            trial.draw = logged(after: trial.start, "draw").first.map { $0.at - trial.start }
            trial.hidden = occlusion(after: trial.end, visible: false).map { $0 - trial.end }
            trial.lastDraw = logged(after: trial.end, "draw").last.map { $0.at - trial.end }
            let routine = ["NSWindowDidLayoutNotification", "NSWindowDidUpdateNotification"]
            trial.notes = lines.lines.withLock { $0 }.filter { line in
                line.at >= trial.start && (line.kind == "note" || line.kind == "app") && !routine.contains { line.text.hasPrefix($0) }
            }.map {
                String(format: "%+.0f ", $0.at - ($0.at < trial.end ? trial.start : trial.end)) + ($0.at < trial.end ? "" : "after the end ")
                    + $0.text.replacingOccurrences(of: "NSWindowDid", with: "").replacingOccurrences(of: "NSApplicationDid", with: "app ")
            }
            if let before, let during, let after {
                trial.shown = Difference(before, during, inside: peekInside(before))
                trial.noise = Difference(before, after, inside: peekInside(before))
            }
            trials.append(trial)
        }
        reportPeeks(variant, trials, window: window)
        kosmos_space_destroy(space)
    }
    cleanup.run()
    exit(0)
}

private func reportPeeks(_ variant: PeekVariant, _ trials: [PeekTrial], window: UInt32) {
    func ms(_ value: Double?) -> String { value.map { String(format: "%.0f", $0) } ?? "never" }
    func median(_ values: [Double]) -> String { values.isEmpty ? "-" : String(format: "%.0f", percentile(values, 0.5)) }
    let currents = trials.compactMap(\.current), visibles = trials.compactMap(\.visible), covers = trials.compactMap(\.cover)
    let draws = trials.compactMap(\.draw), hiddens = trials.compactMap(\.hidden)
    print("\(variant.rawValue) (alpha \(variant.alpha)): current in \(currents.count) of \(trials.count), \(median(currents)) ms from the peek at the median, "
          + "\(ms(currents.max())) at most\(covers.isEmpty ? "" : ", after the cover's \(median(covers)) ms at the median, \(ms(covers.max())) at most"); occlusion visible in \(visibles.count), \(median(visibles)) ms; first draw in \(draws.count), \(median(draws)) ms; "
          + "hidden again in \(hiddens.count), \(median(hiddens)) ms after the conceal; hit by a click at its center during \(trials.filter { $0.hit.during == Int(window) }.count), "
          + "before \(trials.filter { $0.hit.before == Int(window) }.count), after \(trials.filter { $0.hit.after == Int(window) }.count)")
    for (index, trial) in trials.enumerated() {
        let shots = trial.captures.prefix(8).map { "\(ms($0.at))+\(ms($0.took)) \($0.shot)\($0.lag.map { " lag \($0)" } ?? "")" }
        print("  \(index + 1): \(trial.cover.map { "cover up in \(ms($0)) ms, then " } ?? "")in the peek Space after \(trial.landed.map { String(format: "%.2f ms", $0 - trial.start) } ?? "never"), "
              + "occlusion visible \(ms(trial.visible)) ms, first draw \(ms(trial.draw)) ms, current \(ms(trial.current)) ms; "
              + "concealed \(trial.concealed.map { String(format: "%.2f ms", $0) } ?? "unconfirmed") after the end, hidden \(ms(trial.hidden)) ms, "
              + "last draw \(trial.lastDraw.map { ms($0) + " ms after the end" } ?? "before the end"); window list \(trial.listed); "
              + "hit test before, during, after: \(trial.hit.before) \(trial.hit.during) \(trial.hit.after)")
        print("     ScreenCaptureKit, ms from the peek + ms taken: \(shots.joined(separator: "; "))\(trial.captures.count > 8 ? "; \(trial.captures.count) in all" : "")")
        print("     screencapture -l: at the first capture \(trial.early.map { "\($0.0) in \(ms($0.1)) ms" } ?? "-"), "
              + "once current \(trial.late.map { "\($0.0) in \(ms($0.1)) ms" } ?? "-")\(trial.cua.map { "; cua-driver \($0.0) in \(ms($0.1)) ms" } ?? "")")
        print("     the area during against before: \(trial.shown.map { "\($0)" } ?? "unread"); after against before: \(trial.noise.map { "\($0)" } ?? "unread")")
        if index == 0 { trial.notes.forEach { print("     " + $0) } }
    }
}
