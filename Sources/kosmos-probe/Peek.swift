// Whether a concealed window can show on its display without the user seeing it, long enough
// for a screenshot of it to be current, then go back into the holding Space (docs/hiding.md).
//
//   kosmos-probe peek [trials] [variant...] [panel] [chrome|finder|textedit|electron[=<app>]...]
//                     [workspace=<name>] [cua]
//                                   Each trial of a variant takes a concealed window out of its
//                                   holding Space as the variant shows it, captures it with
//                                   ScreenCaptureKit until a capture is current, once with
//                                   `screencapture -l`, and the screen around it, then conceals
//                                   it again. It reads the front app, its key window, Kosmos's
//                                   focus and the pointer before and after each trial. A peek
//                                   before each variant's trials stops a variant that should
//                                   hide the window when the screen shows it. Each variant runs
//                                   5 trials by default, or the variants named run alone:
//                                     plain    in its display's current Space at its own frame,
//                                              which the user sees
//                                     corner   the same, moved first so that only its corner
//                                              point stays on its display, past a bottom corner
//                                              with no display beyond either edge if there is
//                                              one, as AeroSpace hid windows
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
//                                   `panel`, the default when no app is named: a child app's
//                                   titled panel at the bottom left of the built-in display
//                                   draws the tenths of a second since its start as 16 black
//                                   and white cells, and stops drawing while its occlusion state
//                                   is not visible, as Chromium does. It logs each draw and every
//                                   notification of its window. It starts off every display and
//                                   lives in a holding Space of the probe's own, made as Kosmos
//                                   makes one, keeping the built-in display's current Space as
//                                   a concealed window keeps its own. It runs every variant.
//                                   Each app named runs plain, corner and covered, or those of
//                                   them named, one app at a time, on a window the probe opens
//                                   without activating its app, which Kosmos manages. Kosmos
//                                   admits it, then `kosmos
//                                   move-node-to-workspace --window-id` sends it to a hidden
//                                   workspace, the one named or an empty one, on the focused
//                                   display first, where Kosmos conceals it in its own holding
//                                   Space. Each peek takes it out of that Space and puts it back.
//                                   A trial stops the app's trials when that workspace is shown,
//                                   the window left Kosmos's holding Space or moved. Content the
//                                   probe changes or reads tells a current capture:
//                                     chrome    Chrome for Testing from Playwright's cache, a
//                                               new instance with a profile of its own, on a
//                                               page that draws the panel's cells in a magenta
//                                               box at its center from the wall clock
//                                     finder    a Finder window on a temporary folder whose one
//                                               file the probe renames before each trial, read
//                                               back from captures with Vision's text reader
//                                     textedit  a TextEdit document whose text the probe sets
//                                               through Accessibility before each trial, read
//                                               the same way
//                                     electron  an Electron app from /Applications, Obsidian
//                                               unless named, launched only when not running;
//                                               a capture counts as current when it is not
//                                               black and differs from the last capture of the
//                                               trial before, as its content is not the probe's
//                                   With `cua`, a CuaDriver daemon already running takes one
//                                   screenshot of the window concealed and one in the first
//                                   trial of each variant. Hit tests read WindowServer and post
//                                   no event. Needs Screen Recording for the terminal, and
//                                   Accessibility too for an app. Ctrl-C conceals the window
//                                   again at its own frame, quits the apps the probe launched,
//                                   closes the windows it opened in apps that were running,
//                                   removes its files and destroys its Spaces.
import AppKit
import CKosmos
import CKosmosSweep
import KosmosSkyLight
@preconcurrency import ScreenCaptureKit
import Synchronization

let peekSize = CGSize(width: 200, height: 120)
private let peekBits = 16
let peekTick = 100.0   // ms per count

enum PeekVariant: String, CaseIterable {
    case plain, corner, clear, faint, clipped, below, tiny, covered

    var alpha: Float {
        switch self {
        case .clear: 0
        case .faint, .clipped: 0.01
        case .plain, .corner, .below, .tiny, .covered: 1
        }
    }

    /// Shown in its display's current Space, with no Space of the probe's.
    var ordinary: Bool { self == .plain || self == .corner }

    /// What an app's window runs; the panel settled the others (docs/hiding.md).
    static let forApps: [PeekVariant] = [.plain, .corner, .covered]
}

/// How far the captures of the screen reach past the window's frame, for its shadow.
private let peekMargin: CGFloat = 40

/// A value a Sendable closure carries across threads, where the probe orders the accesses.
struct Unchecked<Value>: @unchecked Sendable {
    let value: Value
}

/// What a capture shows, against what the window shows at that moment.
struct Verdict: Sendable, CustomStringConvertible {
    /// Nil when the capture says nothing about it.
    var current: Bool?
    var text: String

    var description: String { text }

    static func failed(_ why: String) -> Verdict { Verdict(current: nil, text: "failed: \(why)") }
}

/// A window the peeks show, concealed in `holding`.
@MainActor protocol PeekTarget: AnyObject {
    var name: String { get }
    var window: UInt32 { get }
    var pid: pid_t { get }
    var holding: UInt64 { get }
    /// Its frame at rest, in CoreGraphics' coordinates.
    var rest: CGRect { get }
    /// The size of its captures in points, or nil for its frame's.
    var captureSize: CGSize? { get }
    /// Judges a capture begun at an uptime, on any thread.
    var judge: @Sendable (CGImage, Double) -> Verdict { get }
    /// Writes its frame back to its rest, from any thread, for the cleanup.
    var putBack: @Sendable () -> Void { get }
    /// The panel's own log of draws and notifications; an app's window has none.
    var log: StubLog? { get }
    /// How many pixels of a capture of the screen only the window shows, or nil when no
    /// colour is its own, so that a change on screen tells it instead.
    var signature: ((Pixels) -> Int)? { get }
    /// Moves it to `frame` and waits for its row to show it there.
    func place(_ frame: CGRect) -> Bool
    /// Changes what it shows, while concealed before a trial.
    func refresh()
    /// After each trial, with its last capture.
    func remember(_ image: CGImage)
    /// Before a trial: nil, or why its trials stop.
    func ready() -> String?
    /// After a peek ends: nil, or why its trials stop.
    func concealedAgain() -> String?
}

/// Steps that undo what the probe set up, run once each, the newest first: at the end, between
/// targets, and at Ctrl-C from another thread.
final class PeekCleanup: @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [(id: Int, run: @Sendable () -> Void)] = []
    private var next = 0

    @discardableResult
    func add(_ step: @escaping @Sendable () -> Void) -> Int {
        lock.withLock {
            next += 1
            steps.append((next, step))
            return next
        }
    }

    /// Forgets a step whose work is done.
    func drop(_ id: Int) { lock.withLock { steps.removeAll { $0.id == id } } }

    func run(_ id: Int) {
        let step = lock.withLock { () -> (@Sendable () -> Void)? in
            guard let index = steps.firstIndex(where: { $0.id == id }) else { return nil }
            return steps.remove(at: index).run
        }
        step?()
    }

    func runAll() {
        while let step = lock.withLock({ steps.popLast()?.run }) { step() }
    }
}

/// A window of the probe's own over an area of the screen, in a Space at level 2, that shows a
/// capture of the area taken before the peek. It is not opaque, so WindowServer does not count
/// the window under it as covered.
@MainActor private final class PeekCover {
    private let window: NSWindow
    private let space: UInt64
    private let cleanup: PeekCleanup, token: Int

    init?(over area: CGRect, cleanup: PeekCleanup) {
        let space = kosmos_float_space_create(2)
        guard space != 0 else { return nil }
        self.space = space
        self.cleanup = cleanup
        token = cleanup.add { kosmos_space_destroy(space) }
        kosmos_space_set_alpha(space, 0)
        window = NSWindow(contentRect: appKitRect(area), styleMask: [.borderless], backing: .buffered, defer: false)
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

    func close() {
        window.orderOut(nil)
        cleanup.run(token)
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
/// `rest` on its standard input moves it to its rest, and `frame x y width height` to that
/// frame in CoreGraphics' coordinates; it runs until its input closes.
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
            let fields = line.split(separator: " ")
            let numbers = fields.dropFirst().compactMap { Double($0) }
            let frame = fields.first == "frame" && numbers.count == 4
                ? CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3]) : nil
            guard frame != nil || line == "rest" else { continue }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    panel.setFrame(appKitRect(frame ?? peekRest()), display: true)
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
struct StubLine: Sendable {
    let at: Double
    let kind: Substring
    let text: Substring
}

final class StubLog: Sendable {
    let lines = Mutex<[StubLine]>([])

    func logged(after time: Double, _ kind: Substring) -> [StubLine] {
        lines.withLock { $0.filter { $0.at >= time && $0.kind == kind } }
    }

    func occlusion(after time: Double, visible: Bool) -> Double? {
        logged(after: time, "note").first {
            $0.text.hasPrefix(NSWindow.didChangeOcclusionStateNotification.rawValue) && $0.text.contains("visible \(visible)")
        }?.at
    }
}

enum Shot: CustomStringConvertible {
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
struct Pixels {
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

    private var opacity: Int { Int(stride(from: 3, to: bytes.count, by: 4).map { bytes[$0] }.max() ?? 0) }

    /// The cells of a box laid out as the panel's content, 200 points wide, whose left and
    /// bottom edges are at `left` and `bottom` in pixels, at `x` and `y` pixels a point.
    private func cells(left: Double, bottom: Double, x: Double, y: Double, opacity: Int) -> Shot {
        let cell = (peekSize.width - 20) / CGFloat(peekBits + 2)
        let row = Int(bottom - 25 * y)
        let bits = (0...(peekBits + 1)).map { light(Int(left + (10 + (CGFloat($0) + 0.5) * cell) * x), row) }
        guard bits.first == true, bits.last == false else { return .unreadable(opacity: opacity) }
        return .count(bits.dropFirst().dropLast().reduce(0) { $0 << 1 | ($1 ? 1 : 0) }, opacity: opacity)
    }

    /// The count the panel drew, from a capture of the panel alone at any scale.
    var count: Shot {
        let opacity = opacity
        guard opacity > 0 else { return .blank }
        return cells(left: 0, bottom: Double(height), x: Double(width) / peekSize.width, y: Double(height) / peekSize.height,
                     opacity: opacity)
    }

    private func isMagenta(_ i: Int) -> Bool { bytes[i] > 200 && bytes[i + 1] < 80 && bytes[i + 2] > 200 }

    /// The count a page drew as the panel's cells in a magenta box 200 points wide, found in a
    /// capture of the whole window.
    var badgeCount: Shot {
        let opacity = opacity
        guard opacity > 0 else { return .blank }
        var (minX, minY, maxX, maxY) = (width, height, -1, -1)
        for y in 0..<height {
            for x in 0..<width where isMagenta((y * width + x) * 4) {
                (minX, minY, maxX, maxY) = (min(minX, x), min(minY, y), max(maxX, x), max(maxY, y))
            }
        }
        guard maxX - minX > 20 else { return .unreadable(opacity: opacity) }
        let scale = Double(maxX - minX + 1) / peekSize.width
        return cells(left: Double(minX), bottom: Double(maxY + 1), x: scale, y: scale, opacity: opacity)
    }

    /// Pixels of the panel's magenta.
    var magenta: Int { stride(from: 0, to: bytes.count, by: 4).filter(isMagenta).count }

    /// The shares of opaque pixels, and of opaque ones near black, which an app that has not
    /// drawn can show.
    var coverage: String {
        var opaque = 0, black = 0
        for i in stride(from: 0, to: bytes.count, by: 4) where bytes[i + 3] == 255 {
            opaque += 1
            if max(bytes[i], bytes[i + 1], bytes[i + 2]) < 10 { black += 1 }
        }
        let total = Double(max(width * height, 1))
        return String(format: "opaque %.1f%%, black %.1f%%", 100 * Double(opaque) / total, 100 * Double(black) / total)
    }
}

/// How two captures of the same area differ, inside and outside a rectangle in pixels.
struct Difference: CustomStringConvertible {
    var inside = (changed: 0, over2: 0, most: 0), outside = (changed: 0, over2: 0, most: 0)

    init(_ a: Pixels, _ b: Pixels, inside rect: CGRect) {
        guard a.width == b.width, a.height == b.height else { return }
        let (left, top, right, bottom) = (Int(rect.minX.rounded(.up)), Int(rect.minY.rounded(.up)),
                                          Int(rect.maxX.rounded(.up)), Int(rect.maxY.rounded(.up)))
        for y in 0..<a.height {
            for x in 0..<a.width {
                let i = (y * a.width + x) * 4
                let delta = max(abs(Int(a.bytes[i]) - Int(b.bytes[i])), abs(Int(a.bytes[i + 1]) - Int(b.bytes[i + 1])),
                                abs(Int(a.bytes[i + 2]) - Int(b.bytes[i + 2])))
                guard delta > 0 else { continue }
                if x >= left && x < right && y >= top && y < bottom {
                    inside = (inside.changed + 1, inside.over2 + (delta > 2 ? 1 : 0), max(inside.most, delta))
                } else {
                    outside = (outside.changed + 1, outside.over2 + (delta > 2 ? 1 : 0), max(outside.most, delta))
                }
            }
        }
    }

    var over2: Int { inside.over2 + outside.over2 }

    var description: String {
        "inside \(inside.changed) px changed, \(inside.over2) by more than 2, most \(inside.most); "
            + "outside \(outside.changed), \(outside.over2), most \(outside.most)"
    }
}

/// An area of one display that the probe captures, around the part of the window it shows.
private struct PeekArea {
    let rect: CGRect, inside: CGRect
    let display: CGDirectDisplayID

    /// `inside` in a capture of the area.
    func inside(_ pixels: Pixels) -> CGRect {
        let scale = CGFloat(pixels.width) / rect.width
        return CGRect(x: (inside.minX - rect.minX) * scale, y: (inside.minY - rect.minY) * scale,
                      width: inside.width * scale, height: inside.height * scale)
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

/// A capture of the window alone, as an agent's screenshot tool takes it, at `size` in points
/// or its own frame's, and the ms it took.
func captureWindow(_ window: UInt32, size: CGSize?) -> (CGImage?, String?, Double) {
    let start = uptime()
    let content = waiting { done in
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { content, _ in done(content) }
    }
    guard let target = content?.windows.first(where: { $0.windowID == window }) else { return (nil, "not shareable", uptime() - start) }
    let filter = SCContentFilter(desktopIndependentWindow: target)
    let configuration = SCStreamConfiguration()
    // The panel's size: the window list's frame follows a Space's scale.
    let size = size ?? target.frame.size
    configuration.width = Int(size.width * CGFloat(filter.pointPixelScale))
    configuration.height = Int(size.height * CGFloat(filter.pointPixelScale))
    configuration.showsCursor = false
    configuration.ignoreShadowsSingleWindow = true
    let (image, error): (CGImage?, String?) = waiting { done in
        SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, error in
            done((image, error.map { $0.localizedDescription }))
        }
    }
    return (image, image == nil ? error ?? "no image" : nil, uptime() - start)
}

private func save(_ image: CGImage, to path: String) {
    guard let file = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(file, image, nil)
    CGImageDestinationFinalize(file)
}

/// What the screen shows over an area of one display.
@MainActor private func captureArea(_ area: PeekArea) -> Pixels? {
    let bounds = CGDisplayBounds(area.display)
    let scale = NSScreen.screens.first { $0.displayID == area.display }?.backingScaleFactor ?? 1
    let content = waiting { done in
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, _ in done(content) }
    }
    guard let display = content?.displays.first(where: { $0.displayID == area.display }) else { return nil }
    let configuration = SCStreamConfiguration()
    configuration.sourceRect = area.rect.offsetBy(dx: -bounds.minX, dy: -bounds.minY)
    configuration.width = Int(area.rect.width * scale)
    configuration.height = Int(area.rect.height * scale)
    configuration.colorSpaceName = CGColorSpace.sRGB
    configuration.showsCursor = false
    let filter = SCContentFilter(display: display, excludingWindows: [])
    let image: CGImage? = waiting { done in
        SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, _ in done(image) }
    }
    return image.map(Pixels.init)
}

/// Runs a command and returns its exit status and combined output.
private func runTool(_ path: String, _ arguments: [String]) -> (Int32, String) {
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

/// A PNG the tool wrote, judged, or why there is none.
private func judged(file path: String, status: Int32, output: String, by judge: (CGImage, Double) -> Verdict, at: Double) -> Verdict {
    defer { try? FileManager.default.removeItem(atPath: path) }
    guard status == 0, let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        return .failed("status \(status): \(output.prefix(160))")
    }
    return judge(image, at)
}

@MainActor private func screencapture(_ target: PeekTarget) -> (Verdict, Double) {
    let start = uptime(), path = NSTemporaryDirectory() + "kosmos-probe-peek.png"
    let (status, output) = runTool("/usr/sbin/screencapture", ["-x", "-o", "-l", "\(target.window)", path])
    return (judged(file: path, status: status, output: output, by: target.judge, at: start), uptime() - start)
}

/// A screenshot through a running CuaDriver daemon, as an agent takes one.
@MainActor private func cuaShot(_ target: PeekTarget) -> (Verdict, Double) {
    let start = uptime(), path = NSTemporaryDirectory() + "kosmos-probe-peek-cua.png"
    try? FileManager.default.removeItem(atPath: path)
    let arguments = #"{"pid":\#(target.pid),"window_id":\#(target.window),"include_accessibility_tree":false,"screenshot_out_file":"\#(path)"}"#
    let (status, output) = runTool(NSHomeDirectory() + "/.local/bin/cua-driver", ["call", "get_window_state", arguments])
    let exists = FileManager.default.fileExists(atPath: path)
    return (judged(file: path, status: exists ? 0 : max(status, 1), output: output, by: target.judge, at: start), uptime() - start)
}

/// What the user's session had before and after a trial: the front app, its key window,
/// Kosmos's focus and display, and the pointer.
private struct PeekWatch: Equatable, CustomStringConvertible {
    var front: pid_t = 0, key: UInt32 = 0
    var kosmos = "unread"
    var pointer = CGPoint.zero

    @MainActor static func read() -> PeekWatch {
        var watch = PeekWatch()
        watch.front = kosmos_front_pid()
        let app = AXUIElementCreateApplication(watch.front)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
           let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
            _ = _AXUIElementGetWindow(unsafeDowncast(value, to: AXUIElement.self), &watch.key)
        }
        if let state = kosmosState() {
            let display = state.workspaces.first { $0.focused }?.display ?? 0
            watch.kosmos = "window \(state.focused?.window ?? 0) on workspace \(state.focused?.workspace ?? "none"), display \(display)"
        }
        let pointer = CGEvent(source: nil)?.location ?? .zero
        watch.pointer = CGPoint(x: pointer.x.rounded(), y: pointer.y.rounded())
        return watch
    }

    var description: String {
        "front pid \(front), key window \(key), Kosmos's focus \(kosmos), pointer (\(Int(pointer.x)), \(Int(pointer.y)))"
    }
}

/// The display that holds the center of `frame`, else the main display.
private func display(holding frame: CGRect) -> CGDirectDisplayID {
    var id: CGDirectDisplayID = 0, count: UInt32 = 0
    guard CGGetDisplaysWithPoint(CGPoint(x: frame.midX, y: frame.midY), 1, &id, &count) == .success, count > 0 else {
        return CGMainDisplayID()
    }
    return id
}

private func activeDisplays() -> [CGDirectDisplayID] {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16), count: UInt32 = 0
    guard CGGetActiveDisplayList(16, &ids, &count) == .success else { return [] }
    return Array(ids.prefix(Int(count)))
}

/// A frame of `size` with only its corner point on `display` and no part on another display,
/// bottom corners first, since AppKit keeps a title bar below the top edge's menu bar; nil
/// when another display lies past an edge at every corner. A corner between two displays would
/// show the window on the other one.
private func cornerFrame(_ size: CGSize, on display: CGRect, besides others: [CGRect]) -> (frame: CGRect, name: String)? {
    let candidates = [
        ("bottom right", CGPoint(x: display.maxX - 1, y: display.maxY - 1)),
        ("bottom left", CGPoint(x: display.minX - size.width + 1, y: display.maxY - 1)),
        ("top right", CGPoint(x: display.maxX - 1, y: display.minY - size.height + 1)),
        ("top left", CGPoint(x: display.minX - size.width + 1, y: display.minY - size.height + 1)),
    ]
    for (name, origin) in candidates {
        let frame = CGRect(origin: origin, size: size)
        if !others.contains(where: { $0.intersects(frame) }) { return (frame, name) }
    }
    return nil
}

/// One capture of the window alone during a trial.
private struct PeekCapture {
    let at: Double, took: Double
    var verdict: Verdict?
}

private struct PeekTrial {
    var start = 0.0, landed: Double?
    /// ms to capture the area and show it over the window, before the peek.
    var cover: Double?
    var captures: [PeekCapture] = []
    var current: Double?
    var early: (Verdict, Double)?, late: (Verdict, Double)?, cua: (Verdict, Double)?
    var visible: Double?, draw: Double?
    var notes: [String] = []
    var end = 0.0, concealed: Double?, hidden: Double?, lastDraw: Double?
    var shown: Difference?, noise: Difference?
    var hit: (before: Int, during: Int, after: Int) = (0, 0, 0)
    var listed: String = ""
    var watch: (before: PeekWatch, after: PeekWatch) = (PeekWatch(), PeekWatch())
}

/// Captures the window alone from `start` until a capture is current or `limit` ms pass. The
/// judging runs on other threads, as reading text takes longer than a capture, so the captures
/// keep coming; a capture counts as current from when it was done, not judged.
@MainActor private func captureUntilCurrent(_ target: PeekTarget, from start: Double, limit: Double, saving prefix: String?,
                                            first: () -> Void) -> (captures: [PeekCapture], last: CGImage?) {
    final class Judged: Sendable {
        let verdicts = Mutex<[Int: Verdict]>([:]), found = Atomic<Bool>(false)
    }
    let judged = Judged(), group = DispatchGroup(), judge = target.judge
    var captures: [PeekCapture] = [], last: CGImage?
    while !judged.found.load(ordering: .relaxed) && uptime() - start < limit {
        let at = uptime()
        let (image, error, took) = captureWindow(target.window, size: target.captureSize)
        let index = captures.count
        captures.append(PeekCapture(at: at - start, took: took, verdict: error.map(Verdict.failed)))
        if let image {
            last = image
            if let prefix, index < 2 { save(image, to: "\(prefix)-\(index).png") }
            let box = Unchecked(value: image)
            DispatchQueue.global(qos: .userInitiated).async(group: group) {
                let verdict = judge(box.value, at)
                judged.verdicts.withLock { $0[index] = verdict }
                if verdict.current == true { judged.found.store(true, ordering: .relaxed) }
            }
        }
        if index == 0 { first() }
    }
    group.wait()
    for (index, verdict) in judged.verdicts.withLock({ $0 }) { captures[index].verdict = verdict }
    return (captures, last)
}

/// Concealed for 3 s: does the window stop drawing, and what does a capture give?
@MainActor private func peekConcealed(_ target: PeekTarget, cua: Bool) {
    pumpEvents(3)
    if let log = target.log {
        let all = log.lines.withLock { $0 }
        let occlusions = all.filter { $0.text.hasPrefix(NSWindow.didChangeOcclusionStateNotification.rawValue) }
        print("concealed for 3 s: visible at its start \(all.first { $0.kind == "start" }?.text.contains("true") == true), "
              + "occlusion changes \(occlusions.map { $0.text.contains("visible true") ? "visible" : "hidden" }), "
              + "\(all.filter { $0.kind == "draw" }.count) draws, the last \(all.last { $0.kind == "draw" }.map { String(format: "%.0f ms before now", uptime() - $0.at) } ?? "never")")
    } else {
        print("\(target.name): concealed for 3 s")
    }
    let at = uptime()
    let (image, error, took) = captureWindow(target.window, size: target.captureSize)
    let held = image.map { target.judge($0, at) } ?? .failed(error ?? "no image")
    let (heldScreencapture, heldScreencaptureTook) = screencapture(target)
    print(String(format: "  ScreenCaptureKit %@ in %.0f ms; screencapture -l %@ in %.0f ms", "\(held)", took, "\(heldScreencapture)", heldScreencaptureTook))
    if cua {
        let (shot, took) = cuaShot(target)
        print(String(format: "  cua-driver %@ in %.0f ms", "\(shot)", took))
    }
}

/// The variants' trials on one window, which starts and ends concealed in its holding Space.
@MainActor private func runPeeks(_ target: PeekTarget, _ variants: [PeekVariant], trials count: Int, cua: Bool, cleanup: PeekCleanup) {
    let window = target.window
    var ids = [window]
    for variant in variants {
        if let reason = target.ready() { return print("\(target.name): \(reason); its trials stop") }
        let rest = target.rest, holding = target.holding
        let screen = display(holding: rest), bounds = CGDisplayBounds(screen)
        let stripped = SkyLight.spaces(of: window)?.isEmpty ?? true
        let ordinary = Displays.current().ordinarySpace(on: screen, original: nil) ?? 0
        var corner: CGRect?
        if variant == .corner {
            guard let found = cornerFrame(rest.size, on: bounds, besides: activeDisplays().filter { $0 != screen }.map(CGDisplayBounds)) else {
                print("corner: another display lies past an edge at each corner of display \(screen)")
                continue
            }
            corner = found.frame
            print("corner: the \(found.name) corner of display \(screen) at \(bounds), the window at \(found.frame)")
        }
        let shownAt = corner ?? rest
        let visible = shownAt.intersection(bounds)
        let area = variant == .corner
            ? PeekArea(rect: CGRect(x: visible.minX - 80, y: visible.minY - 80, width: 161, height: 161).intersection(bounds),
                       inside: visible, display: screen)
            : PeekArea(rect: rest.insetBy(dx: -peekMargin, dy: -peekMargin).intersection(bounds), inside: rest, display: screen)
        let point = CGPoint(x: visible.midX, y: visible.midY)
        func hit() -> Int {
            NSWindow.windowNumber(at: NSPoint(x: point.x, y: NSScreen.screens[0].frame.height - point.y), belowWindowWithWindowNumber: 0)
        }
        var space: UInt64 = 0, spaceToken: Int?
        if !variant.ordinary {
            var ordinaryLevel: Int32 = 0
            if variant == .below && !kosmos_peek_space_level(ordinary, &ordinaryLevel) {
                print("\(variant.rawValue): the level of Space \(ordinary) did not read")
                continue
            }
            space = kosmos_float_space_create(variant == .below ? ordinaryLevel - 1 : 1)
            guard space != 0 else { print("\(variant.rawValue): no Space"); continue }
            let created = space
            spaceToken = cleanup.add { kosmos_space_destroy(created) }
            // Transparent before the window joins it, as a pop's Space.
            kosmos_space_set_alpha(space, variant == .below || variant == .covered ? 0 : variant.alpha)
        }
        defer { spaceToken.map(cleanup.run) }
        if variant == .clipped {
            var shape = CGRect.null
            let set = kosmos_peek_space_set_shape(space, CGRect(origin: rest.origin, size: CGSize(width: 1, height: 1)))
            let read = kosmos_peek_space_shape(space, &shape)
            print("\(variant.rawValue): shape set \(set), read \(read ? "\(shape)" : "failed")")
        }
        if variant == .tiny { kosmos_space_set_transform(space, CGAffineTransform(scaleX: 400, y: 400)) }
        let cover = variant == .covered ? PeekCover(over: area.rect, cleanup: cleanup) : nil
        if variant == .covered && cover == nil { print("\(variant.rawValue): no cover"); continue }
        defer { cover?.close() }

        /// Out of the holding Space, after the corner move, or back; the uptime it landed.
        func move(peek: Bool) -> Double? {
            let start = uptime()
            switch (variant.ordinary, peek) {
            case (true, true):
                // A window removed from its only Space lands on the active Space (docs/hiding.md).
                if stripped {
                    kosmos_add_windows(ordinary, &ids, 1, true)
                    _ = kosmos_barrier(holding)
                }
                kosmos_remove_windows(holding, &ids, 1)
            case (true, false):
                // An exclusive add strips it again, as Kosmos strips a window it conceals.
                kosmos_add_windows(holding, &ids, 1, stripped)
            case (false, true):
                kosmos_add_windows(space, &ids, 1, variant == .below)
                kosmos_remove_windows(holding, &ids, 1)
            case (false, false):
                kosmos_add_windows(holding, &ids, 1, false)
                kosmos_remove_windows(space, &ids, 1)
            }
            while uptime() - start < 10 && inSpace(window, holding) == peek { usleep(100) }
            if inSpace(window, holding) == peek { _ = kosmos_barrier(holding) }
            return inSpace(window, holding) == peek ? nil : uptime()
        }
        /// Registered before the window leaves its frame or its Space, so Ctrl-C puts it back.
        func undo() -> Int {
            let (peekSpace, exclusive, cornered, putBack) = (space, variant.ordinary && stripped, corner != nil, target.putBack)
            return cleanup.add {
                var ids = [window]
                kosmos_add_windows(holding, &ids, 1, exclusive)
                if peekSpace != 0 { kosmos_remove_windows(peekSpace, &ids, 1) }
                _ = kosmos_barrier(holding)
                if cornered { putBack() }
            }
        }
        func show() -> Double? {
            if let corner, !target.place(corner) { return nil }
            return move(peek: true)
        }
        func conceal() -> Double? {
            let landed = move(peek: false)
            if corner != nil { _ = target.place(rest) }
            return landed
        }

        // A peek before the trials, read back at once, stops a variant that should hide the
        // window when the screen shows it. Under the desktop picture, and under the cover, only
        // then does the Space go to alpha 1, and back to alpha 0 once the screen shows it.
        if variant != .plain {
            let token = undo()
            let first = captureArea(area)
            if let first { cover?.show(first.image) }
            guard show() != nil else {
                cleanup.run(token)
                print("\(variant.rawValue): the window did not leave its holding Space or did not reach its frame")
                continue
            }
            var seen = captureArea(area)
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
                    seen = captureArea(area)
                }
            }
            if variant == .covered && seen != nil {
                kosmos_space_set_alpha(space, 1)
                seen = captureArea(area)
            }
            let difference = first.flatMap { first in seen.map { Difference(first, $0, inside: area.inside(first)) } }
            let shows: Bool, seenText: String
            if let signature = target.signature {
                // The scaled panel can show as a pixel or two.
                let pixels = seen.map(signature) ?? -1
                shows = variant != .corner && (pixels < 0 || pixels > (variant == .tiny ? 4 : 0))
                seenText = "the screen showed \(pixels) of its pixels"
            } else {
                shows = variant != .corner && (difference?.over2 ?? 1) > 0
                seenText = "the screen changed by more than 2 levels in \(difference?.over2 ?? -1) pixels"
            }
            if shows && variant.alpha == 1 && space != 0 { kosmos_space_set_alpha(space, 0) }
            _ = conceal()
            cleanup.drop(token)
            cover?.hide()
            print("\(target.name) \(variant.rawValue): \(seenText) in a peek before the trials"
                  + (difference.map { "; the area against before it: \($0)" } ?? ""))
            if let reason = target.concealedAgain() { return print("\(target.name): \(reason); its trials stop") }
            guard !shows else { continue }
        }
        var trials: [PeekTrial] = []
        for index in 1...count {
            target.refresh()
            pumpEvents(1.5)
            if let reason = target.ready() {
                print("\(target.name): \(reason); its trials stop")
                break
            }
            var trial = PeekTrial()
            trial.watch.before = PeekWatch.read()
            let token = undo()
            let coverStart = uptime()
            let before = captureArea(area)
            if let before, let cover {
                cover.show(before.image)
                trial.cover = uptime() - coverStart
            }
            trial.hit.before = hit()
            // The corner move happens concealed, before the peek starts.
            if let corner, !target.place(corner) {
                cleanup.run(token)
                print("\(target.name) corner: the window did not reach its corner frame; its trials stop")
                break
            }
            trial.start = uptime()
            trial.landed = move(peek: true)
            let prefix = index == 1 ? NSTemporaryDirectory() + "kosmos-probe-peek-\(target.name.lowercased().replacingOccurrences(of: " ", with: "-"))-\(variant.rawValue)" : nil
            let (captures, last) = captureUntilCurrent(target, from: trial.start, limit: 3000, saving: prefix) {
                trial.early = screencapture(target)
            }
            trial.captures = captures
            trial.current = captures.first { $0.verdict?.current == true }.map { $0.at + $0.took }
            trial.late = screencapture(target)
            if cua && index == 1 { trial.cua = cuaShot(target) }
            trial.hit.during = hit()
            let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], window) as? [[String: Any]])?.first
            trial.listed = "on screen \((info?[kCGWindowIsOnscreen as String] as? Bool) ?? false), "
                + "bounds \((info?[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) }.map { "\($0)" } ?? "none")"
            let during = captureArea(area)
            trial.end = uptime()
            trial.concealed = move(peek: false).map { $0 - trial.end }
            if corner != nil { _ = target.place(rest) }
            cleanup.drop(token)
            cover?.hide()
            if let last { target.remember(last) }
            let stop = target.concealedAgain()
            pumpEvents(1.5)
            let after = captureArea(area)
            trial.hit.after = hit()
            trial.watch.after = PeekWatch.read()
            if let log = target.log {
                trial.visible = log.occlusion(after: trial.start, visible: true).map { $0 - trial.start }
                trial.draw = log.logged(after: trial.start, "draw").first.map { $0.at - trial.start }
                trial.hidden = log.occlusion(after: trial.end, visible: false).map { $0 - trial.end }
                trial.lastDraw = log.logged(after: trial.end, "draw").last.map { $0.at - trial.end }
                let routine = ["NSWindowDidLayoutNotification", "NSWindowDidUpdateNotification"]
                trial.notes = log.lines.withLock { $0 }.filter { line in
                    line.at >= trial.start && (line.kind == "note" || line.kind == "app") && !routine.contains { line.text.hasPrefix($0) }
                }.map {
                    String(format: "%+.0f ", $0.at - ($0.at < trial.end ? trial.start : trial.end)) + ($0.at < trial.end ? "" : "after the end ")
                        + $0.text.replacingOccurrences(of: "NSWindowDid", with: "").replacingOccurrences(of: "NSApplicationDid", with: "app ")
                }
            }
            if let before, let during, let after {
                trial.shown = Difference(before, during, inside: area.inside(before))
                trial.noise = Difference(before, after, inside: area.inside(before))
            }
            trials.append(trial)
            if let stop {
                print("\(target.name): \(stop); its trials stop")
                break
            }
        }
        reportPeeks(target, variant, trials)
    }
}

@MainActor private func reportPeeks(_ target: PeekTarget, _ variant: PeekVariant, _ trials: [PeekTrial]) {
    func ms(_ value: Double?) -> String { value.map { String(format: "%.0f", $0) } ?? "never" }
    func median(_ values: [Double]) -> String { values.isEmpty ? "-" : String(format: "%.0f", percentile(values, 0.5)) }
    let window = target.window, logged = target.log != nil
    let currents = trials.compactMap(\.current), covers = trials.compactMap(\.cover)
    let unchanged = trials.filter { $0.watch.before == $0.watch.after }.count
    var line = "\(target.name) \(variant.rawValue) (alpha \(variant.alpha)): current in \(currents.count) of \(trials.count), "
        + "\(median(currents)) ms from the peek at the median, \(ms(currents.max())) at most"
        + (covers.isEmpty ? "" : ", after the cover's \(median(covers)) ms at the median, \(ms(covers.max())) at most")
    if logged {
        let visibles = trials.compactMap(\.visible), draws = trials.compactMap(\.draw), hiddens = trials.compactMap(\.hidden)
        line += "; occlusion visible in \(visibles.count), \(median(visibles)) ms; first draw in \(draws.count), \(median(draws)) ms; "
            + "hidden again in \(hiddens.count), \(median(hiddens)) ms after the conceal"
    }
    line += "; hit by a click at its center during \(trials.filter { $0.hit.during == Int(window) }.count), "
        + "before \(trials.filter { $0.hit.before == Int(window) }.count), after \(trials.filter { $0.hit.after == Int(window) }.count); "
        + "front app, key window, Kosmos's focus and pointer unchanged in \(unchanged) of \(trials.count)"
    print(line)
    for (index, trial) in trials.enumerated() {
        let shots = trial.captures.prefix(8).map { "\(ms($0.at))+\(ms($0.took)) \($0.verdict.map { "\($0)" } ?? "unjudged")" }
        print("  \(index + 1): \(trial.cover.map { "cover up in \(ms($0)) ms, then " } ?? "")out of the holding Space after \(trial.landed.map { String(format: "%.2f ms", $0 - trial.start) } ?? "never"), "
              + (logged ? "occlusion visible \(ms(trial.visible)) ms, first draw \(ms(trial.draw)) ms, " : "")
              + "current \(ms(trial.current)) ms, peek \(ms(trial.end - trial.start)) ms; "
              + "concealed \(trial.concealed.map { String(format: "%.2f ms", $0) } ?? "unconfirmed") after the end"
              + (logged ? ", hidden \(ms(trial.hidden)) ms, last draw \(trial.lastDraw.map { ms($0) + " ms after the end" } ?? "before the end")" : "")
              + "; window list \(trial.listed); hit test before, during, after: \(trial.hit.before) \(trial.hit.during) \(trial.hit.after)")
        print("     ScreenCaptureKit, ms from the peek + ms taken: \(shots.joined(separator: "; "))\(trial.captures.count > 8 ? "; \(trial.captures.count) in all" : "")")
        print("     screencapture -l: at the first capture \(trial.early.map { "\($0.0) in \(ms($0.1)) ms" } ?? "-"), "
              + "at the end \(trial.late.map { "\($0.0) in \(ms($0.1)) ms" } ?? "-")\(trial.cua.map { "; cua-driver \($0.0) in \(ms($0.1)) ms" } ?? "")")
        print("     the area during against before: \(trial.shown.map { "\($0)" } ?? "unread"); after against before: \(trial.noise.map { "\($0)" } ?? "unread")")
        if trial.watch.before != trial.watch.after {
            print("     changed: before \(trial.watch.before); after \(trial.watch.after)")
        }
        if index == 0 { trial.notes.forEach { print("     " + $0) } }
    }
}

/// The probe's panel, concealed in a holding Space of the probe's own.
@MainActor private final class PanelTarget: PeekTarget {
    let name = "panel"
    let window: UInt32, pid: pid_t, holding: UInt64, rest: CGRect
    let captureSize: CGSize? = peekSize
    let judge: @Sendable (CGImage, Double) -> Verdict
    let putBack: @Sendable () -> Void
    let log: StubLog?
    let signature: ((Pixels) -> Int)? = { $0.magenta }
    private let child: Child

    init(window: UInt32, child: Child, holding: UInt64, rest: CGRect, born: Double, log: StubLog) {
        (self.window, self.child, self.holding, self.rest, self.log) = (window, child, holding, rest, log)
        pid = child.pid
        judge = { image, at in
            let pixels = Pixels(image), shot = pixels.count
            guard case .count(let shown, _) = shot else { return Verdict(current: nil, text: "\(shot)") }
            let lag = Int((at - born) / peekTick) - shown
            return Verdict(current: lag <= 1, text: "\(shot) lag \(lag), \(pixels.coverage)")
        }
        let box = Unchecked(value: child)
        putBack = { box.value.send("rest") }
    }

    func place(_ frame: CGRect) -> Bool {
        child.send(String(format: "frame %.0f %.0f %.0f %.0f", frame.minX, frame.minY, frame.width, frame.height))
        let start = uptime()
        while uptime() - start < 1000 {
            if let row = SkyLight.rows([window])?.first?.frame, abs(row.minX - frame.minX) < 1, abs(row.minY - frame.minY) < 1 { return true }
            usleep(2000)
        }
        return false
    }

    func refresh() {}
    func remember(_ image: CGImage) {}
    func ready() -> String? { nil }
    func concealedAgain() -> String? { nil }
}

/// The panel's app, its panel off every display in a holding Space of the probe's, then at its
/// rest; nil when it could not be set up.
@MainActor private func panelTarget(cleanup: PeekCleanup) -> PanelTarget? {
    let child = Child(["peek-window"])
    let header = child.line().split(separator: " ")
    guard header.count == 2, let window = UInt32(header[0]), let born = Double(header[1]) else {
        print("error: no panel")
        child.terminate()
        return nil
    }
    let log = StubLog()
    child.onLines { line in
        let fields = line.split(separator: " ", maxSplits: 2)
        guard fields.count >= 2, let at = Double(fields[0]) else { return }
        log.lines.withLock { $0.append(StubLine(at: at, kind: fields[1], text: fields.count > 2 ? fields[2] : "")) }
    }
    let holding = kosmos_holding_create()
    guard holding != 0 else { print("error: no holding Space"); child.terminate(); return nil }
    cleanup.add { kosmos_space_destroy(holding) }
    let box = Unchecked(value: child)
    cleanup.add { box.value.quit() }
    var ids = [window]
    kosmos_add_windows(holding, &ids, 1, false)
    _ = kosmos_barrier(holding)
    child.send("rest")
    let rest = peekRest()
    var waited = 0
    while log.logged(after: 0, "rest").isEmpty && waited < 100 { pumpEvents(0.01); waited += 1 }

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
    return PanelTarget(window: window, child: child, holding: holding, rest: rest, born: born, log: log)
}

@MainActor func peek(trials count: Int, arguments: [String]) -> Never {
    var variants: [PeekVariant] = [], apps: [PeekApp] = [], panel = false, cua = false
    var workspace: String?
    for argument in arguments {
        if let variant = PeekVariant(rawValue: argument) {
            variants.append(variant)
        } else if let app = PeekApp(argument) {
            apps.append(app)
        } else if argument.hasPrefix("workspace="), argument.count > 10 {
            workspace = String(argument.dropFirst(10))
        } else if argument == "panel" || argument == "cua" {
            panel = panel || argument == "panel"
            cua = cua || argument == "cua"
        } else {
            usage()
        }
    }
    panel = panel || apps.isEmpty
    let appVariants = variants.isEmpty ? PeekVariant.forApps : variants.filter(PeekVariant.forApps.contains)
    if !apps.isEmpty && appVariants.isEmpty {
        print("error: an app's window runs only \(PeekVariant.forApps.map(\.rawValue).joined(separator: ", "))")
        exit(2)
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    if panel && !NSScreen.screens.contains(where: { CGDisplayIsBuiltin($0.displayID) != 0 }) {
        print("error: the built-in display is off")
        exit(1)
    }
    guard CGPreflightScreenCaptureAccess() else {
        print("error: this terminal has no Screen Recording permission")
        exit(1)
    }
    var hidden: String?
    if !apps.isEmpty {
        guard AXIsProcessTrusted() else {
            print("error: this terminal has no Accessibility permission, which the apps' windows need")
            exit(1)
        }
        guard let state = kosmosState() else {
            print("error: Kosmos did not answer kosmos state; an app's window is concealed by Kosmos")
            exit(1)
        }
        hidden = peekWorkspace(named: workspace, in: state)
        guard let hidden else {
            print("error: " + (workspace.map { "workspace \($0) is shown or unknown" } ?? "no hidden workspace is empty; name one with workspace=<name>"))
            exit(1)
        }
        print("the apps' windows go to workspace \(hidden), which no display shows")
    }
    let cleanup = PeekCleanup()
    signal(SIGINT, SIG_IGN)
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    // Sendable, so it runs off the main actor while the main thread waits on a capture.
    interrupt.setEventHandler { @Sendable in
        cleanup.runAll()
        print("interrupted; cleaned up")
        exit(130)
    }
    interrupt.resume()

    if panel, let target = panelTarget(cleanup: cleanup) {
        peekConcealed(target, cua: cua)
        runPeeks(target, variants.isEmpty ? PeekVariant.allCases : variants, trials: count, cua: cua, cleanup: cleanup)
        cleanup.runAll()
    }
    for app in apps {
        if let hidden, let target = appTarget(app, on: hidden, cleanup: cleanup) {
            peekConcealed(target, cua: cua)
            runPeeks(target, appVariants, trials: count, cua: cua, cleanup: cleanup)
        }
        cleanup.runAll()
        print("\(app.name): cleaned up")
    }
    exit(0)
}
