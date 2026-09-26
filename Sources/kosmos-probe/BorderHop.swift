// A border that follows the focus between displays (docs/borders.md).
//
//   kosmos-probe border-hop [one|per-display] [hops]
//                                   A border hopping between a child app's windows on the
//                                   built-in display and a display that is not the main one,
//                                   with one border window or one for each display: the main
//                                   thread's time per hop, Space moves and stray frames.
//   kosmos-probe border-watch <window> [seconds]
//                                   Passive: a window's bounds and Spaces every 1.5 ms, and
//                                   what the built-in display shows of it, at log times.
import AppKit
import CKosmos
import KosmosSkyLight
@preconcurrency import ScreenCaptureKit

/// WindowServer's bounds and Spaces of windows, sampled on a thread of its own.
final class WindowSampler: @unchecked Sendable {
    struct Sample {
        var time: Double
        var window: UInt32
        var bounds: CGRect
        var spaces: [UInt64]

        var line: String { "bounds \(bounds), Spaces \(spaces)" }
    }

    private let lock = NSLock()
    private var samples: [Sample] = []
    private var running = true

    init(_ windows: [UInt32]) {
        Thread.detachNewThread { [self] in
            while lock.withLock({ running }) {
                for window in windows {
                    let time = CACurrentMediaTime()
                    let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], window) as? [[String: Any]])?.first
                    let bounds = (info?[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) }
                    let sample = Sample(time: time, window: window, bounds: bounds ?? .null,
                                        spaces: SkyLight.spaces(of: window) ?? [])
                    lock.withLock { samples.append(sample) }
                }
                usleep(1500)
            }
        }
    }

    func stop() -> [Sample] {
        lock.withLock {
            running = false
            return samples
        }
    }
}

@MainActor func borderHop(perDisplay: Bool, hops: Int) -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.finishLaunching()
    let builtIn = builtInScreen()
    guard builtIn != NSScreen.screens[0], let other = NSScreen.screens.dropFirst().first(where: { $0 != builtIn }) else {
        print("needs the built-in display and another one, neither of them the main display")
        exit(1)
    }
    let targets = Child(["border-targets", "2"])
    let windows = targets.readWindows()
    let (a, b) = (windows[0], windows[1])
    for (id, frame) in [(a, NSRect(x: builtIn.visibleFrame.minX + 60, y: builtIn.visibleFrame.minY + 60, width: 900, height: 600)),
                        (b, NSRect(x: other.visibleFrame.minX + 120, y: other.visibleFrame.minY + 80, width: 1300, height: 820))] {
        targets.send("frame \(id) \(Int(frame.minX)) \(Int(frame.minY)) \(Int(frame.width)) \(Int(frame.height))")
        _ = targets.line()
    }
    pumpEvents(0.5)
    func spaces(_ window: UInt32) -> [UInt64] { SkyLight.spaces(of: window) ?? [] }
    let rows = Dictionary(SkyLight.rows([a, b], cornerRadii: true).map { ($0.id, $0) }) { first, _ in first }
    print("A \(a) on the built-in display, Spaces \(spaces(a)); B \(b) on \(other.localizedName), Spaces \(spaces(b))")
    let color = CGColor(srgbRed: 0x7a / 255, green: 0xa2 / 255, blue: 0xf7 / 255, alpha: 1)
    let width: CGFloat = 4
    func ring(_ target: UInt32) -> CGRect { rows[target]!.frame.insetBy(dx: -width / 2, dy: -width / 2) }

    let borders = perDisplay ? [ProbeBorder(), ProbeBorder()] : [ProbeBorder()]
    func border(for target: UInt32) -> ProbeBorder { perDisplay && target == b ? borders[1] : borders[0] }
    func show(_ probe: ProbeBorder, around target: UInt32) {
        probe.place(around: appKitRect(rows[target]!.frame), radius: rows[target]!.cornerRadius, width: width, color: color)
        probe.window.order(.below, relativeTo: Int(target))
    }
    // Kosmos's pin: on another queue, a move to the target's Space when the border is in none
    // of the target's.
    let queue = DispatchQueue(label: "kosmos.borders", qos: .userInitiated)
    let pinLock = NSLock()
    nonisolated(unsafe) var moves: [(time: Double, from: [UInt64], to: UInt64)] = []
    func pin(_ probe: ProbeBorder, to target: UInt32) {
        let border = probe.id
        queue.async {
            let ordinary = Displays.current().ordinarySpaces
            let targetSpaces = (SkyLight.spaces(of: target) ?? []).filter(ordinary.contains)
            let borderSpaces = SkyLight.spaces(of: border) ?? []
            guard let space = targetSpaces.first, Set(targetSpaces).isDisjoint(with: borderSpaces) else { return }
            SLSMoveWindowsToManagedSpace(SkyLight.connection, [border] as CFArray, space)
            let time = CACurrentMediaTime()
            pinLock.withLock { moves.append((time, borderSpaces, space)) }
        }
    }
    for target in perDisplay ? [a, b] : [a] {
        show(border(for: target), around: target)
        pin(border(for: target), to: target)
    }
    if perDisplay { borders[1].window.orderOut(nil) }
    pumpEvents(0.3)
    print("borders \(borders.map(\.id)) in Spaces \(borders.map { spaces($0.id) })")

    let sampler = WindowSampler(borders.map(\.id))
    var current = a, costs: [Double] = [], starts: [Double] = []
    for _ in 0..<hops {
        let next = current == a ? b : a
        let start = CACurrentMediaTime()
        // As Borders.show: the border leaves the focus's last window and shows around the next.
        border(for: current).window.orderOut(nil)
        show(border(for: next), around: next)
        costs.append((CACurrentMediaTime() - start) * 1000)
        pin(border(for: next), to: next)
        starts.append(start)
        pumpEvents(0.5)
        current = next
    }
    let samples = sampler.stop()
    for probe in borders { probe.window.orderOut(nil) }
    targets.quit()

    for (index, start) in starts.enumerated() {
        let target = index % 2 == 0 ? b : a
        func ms(_ time: Double) -> String { String(format: "%.1f ms", (time - start) * 1000) }
        print(String(format: "hop %d to %@: main thread %.3f ms", index + 1, target == a ? "A" : "B", costs[index]))
        for move in pinLock.withLock({ moves }) where move.time >= start && move.time < start + 0.5 {
            print("  \(ms(move.time)): moved from Spaces \(move.from) to \(move.to)")
        }
        for sample in samples where sample.time >= start && sample.time < start + 0.5 && !sample.bounds.isNull
            && sample.bounds != ring(a) && sample.bounds != ring(b) {
            print("  \(ms(sample.time)): border \(sample.window) at \(sample.line)")
        }
    }
    let sorted = costs.sorted()
    print(String(format: "main thread per hop: %.3f ms median, %.3f ms at most", sorted[sorted.count / 2], sorted.last!))
    exit(0)
}

/// Each complete frame's box of pixels brighter than black, in global coordinates.
final class FrameBoxes: NSObject, SCStreamOutput, @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [(time: Double, box: CGRect?)] = []
    private let origin: CGPoint
    private let scale: CGFloat
    private let seconds: Double

    init(origin: CGPoint, scale: CGFloat) {
        self.origin = origin
        self.scale = scale
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        seconds = Double(timebase.numer) / Double(timebase.denom) / 1e9
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first, let status = info[.status] as? Int, SCFrameStatus(rawValue: status) == .complete,
              let pixels = CMSampleBufferGetImageBuffer(buffer) else { return }
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
        let row = CVPixelBufferGetBytesPerRow(pixels)
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in 0..<CVPixelBufferGetHeight(pixels) {
            for x in 0..<CVPixelBufferGetWidth(pixels) {
                let pixel = base + y * row + x * 4
                guard max(pixel[0], pixel[1], pixel[2]) > 40 else { continue }
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        let box = maxX < 0 ? nil : CGRect(x: origin.x + CGFloat(minX) / scale, y: origin.y + CGFloat(minY) / scale,
                                          width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
        let time = Double(info[.displayTime] as? UInt64 ?? 0) * seconds
        lock.withLock { frames.append((time, box)) }
    }

    func stop() -> [(time: Double, box: CGRect?)] { lock.withLock { frames } }
}

@MainActor func borderWatch(_ window: UInt32, seconds: Double) -> Never {
    NSApplication.shared.setActivationPolicy(.prohibited)
    nonisolated(unsafe) var content: SCShareableContent?
    let ready = DispatchSemaphore(value: 0)
    SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { result, error in
        if let error { print("no capture: \(error)") }
        content = result
        ready.signal()
    }
    ready.wait()
    let builtIn = builtInScreen().displayID
    var stream: SCStream?
    var boxes: FrameBoxes?
    if let target = content?.windows.first(where: { $0.windowID == window }),
       let display = content?.displays.first(where: { $0.displayID == builtIn }) {
        let configuration = SCStreamConfiguration()
        configuration.width = display.width / 2
        configuration.height = display.height / 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 120)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = false
        let output = FrameBoxes(origin: CGDisplayBounds(builtIn).origin, scale: 0.5)
        let capture = SCStream(filter: SCContentFilter(display: display, including: [target]), configuration: configuration, delegate: nil)
        try! capture.addStreamOutput(output, type: .screen, sampleHandlerQueue: DispatchQueue(label: "capture"))
        capture.startCapture { error in
            if let error { print("no capture: \(error)") }
            ready.signal()
        }
        ready.wait()
        (stream, boxes) = (capture, output)
    }
    let sampler = WindowSampler([window])
    pumpEvents(seconds)
    stream?.stopCapture { _ in }
    var lines: [(time: Double, text: String)] = []
    var last = ""
    for sample in sampler.stop() where sample.line != last {
        lines.append((sample.time, sample.line))
        last = sample.line
    }
    last = ""
    for frame in boxes?.stop() ?? [] {
        let text = "built-in display shows it at \(frame.box.map { "\($0)" } ?? "nothing")"
        if text != last { lines.append((frame.time, text)) }
        last = text
    }
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
    let offset = Date().timeIntervalSince1970 - CACurrentMediaTime()
    for line in lines.sorted(by: { $0.time < $1.time }) {
        print("\(formatter.string(from: Date(timeIntervalSince1970: line.time + offset))) \(line.text)")
    }
    exit(0)
}
