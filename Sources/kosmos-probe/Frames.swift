// The screen side of script/bench-frames.sh (docs/geometry.md).
//
//   kosmos-probe bench-frames <directory> <display> [real]
//                                   Records the built-in display at its refresh rate and
//                                   measures each step the script names on stdin, keeping only
//                                   per frame figures and pictures of flagged frames in the
//                                   directory. It exits before recording unless the built-in
//                                   display has the name given, as `kosmos state` gives it.
//                                   `real` says a window of Steve's is in the run. Needs Screen
//                                   Recording for the terminal it runs from, and exits rather
//                                   than ask for it.
//
// It prints `display <name>\t<Hz>\t<width>x<height>` as it starts, then answers each line on
// stdin:
//   wallpaper                        `ok` once the screen is still, keeping it as the desktop
//   step <n> <rep> <expect> <action> `armed <n>` once the screen is still, with that frame as
//                                    the state before the step; expect is instant or slide
//   sent <n> <sent> <answered> <exit>
//                                    `done <n> <latency ms> <frames> <stalls> <jumps> <displaced>
//                                    <flashes> <settle>` once the screen settles, with the step
//                                    measured
//   end                              `end` once table.txt and the files beside it are written
// or `abort <why>` when free disk falls under 20 GB or the directory passes 500 MB.
import AppKit
import CoreMedia
import KosmosBench
import ScreenCaptureKit

@MainActor func benchFrames(_ directory: String, display: String, real: Bool) -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    guard let screen = NSScreen.screens.first(where: { CGDisplayIsBuiltin($0.displayID) != 0 }) else {
        print("error: the built-in display is off")
        exit(1)
    }
    guard screen.localizedName == display else {
        print("error: the run's workspace is on \(display), and the capture records only the built-in display, \(screen.localizedName)")
        exit(1)
    }
    // Asking would show a prompt, which the bench must never do.
    guard CGPreflightScreenCaptureAccess() else {
        print("error: this terminal has no Screen Recording permission; run the bench from one that has it")
        exit(1)
    }
    // In the display's points from its top left: the area under the menu bar and the notch.
    let frame = screen.frame, visible = screen.visibleFrame
    let top = min(visible.maxY, frame.maxY - screen.safeAreaInsets.top)
    let area = CGRect(x: visible.minX - frame.minX, y: frame.maxY - top, width: visible.width, height: top - visible.minY)
    let rate = max(screen.maximumFramesPerSecond, 1), width = Int(area.width / 2), height = Int(area.height / 2)
    let recorder = Recorder(directory: URL(fileURLWithPath: directory), display: screen.localizedName, refresh: 1 / Double(rate),
                            real: real) { print($0) }
    print("display \(screen.localizedName)\t\(rate)\t\(width)x\(height)")
    let capture = Capture(displayID: screen.displayID, area: area, width: width, height: height, rate: rate) { picture in
        onMain(recorder) { recorder.add(picture) }
    } failed: { why in
        onMain(recorder) { recorder.abort("capture: \(why)") }
    }
    capture.start()
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now(), repeating: .milliseconds(5))
    timer.setEventHandler { onMain(recorder) { recorder.check(at: Date().timeIntervalSince1970) } }
    timer.resume()
    // Notification Center's windows on the display, read 5 times a second: a banner there shows
    // in the frames, and its steps' events can be discounted. The window list's owner names
    // and bounds need no permission of their own.
    let bounds = CGDisplayBounds(screen.displayID)
    let banners = DispatchSource.makeTimerSource(queue: .main)
    banners.schedule(deadline: .now(), repeating: .milliseconds(200))
    banners.setEventHandler {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[CFString: Any]] ?? []
        let shown = windows.compactMap { window -> (id: Int, rect: CGRect)? in
            guard (window[kCGWindowOwnerName] as? String)?.contains("Notification") == true,
                  let id = window[kCGWindowNumber] as? Int, let box = window[kCGWindowBounds] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: box), rect.intersects(bounds),
                  (window[kCGWindowAlpha] as? Double ?? 1) > 0 else { return nil }
            return (id, rect)
        }
        onMain(recorder) { if !shown.isEmpty { recorder.banners(shown, at: Date().timeIntervalSince1970) } }
    }
    banners.resume()
    Thread.detachNewThread {
        while let line = readLine() { onMain(recorder) { recorder.command(line, at: Date().timeIntervalSince1970) } }
        onMain(recorder) { recorder.finish() }
    }
    app.run()
    exit(0)
}

/// Runs the work on the main actor, and exits once the recorder has finished.
private func onMain(_ recorder: Recorder, _ work: @escaping @MainActor @Sendable () -> Void) {
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            work()
            if recorder.finished { exit(0) }
        }
    }
}

/// AppKit has a Picture of its own.
typealias Picture = KosmosBench.Picture

/// A ScreenCaptureKit stream of one display's area, scaled to 2 points a pixel, in sRGB, at the
/// display's refresh rate. It keeps no frame: each is copied out and handed on, so the
/// stream's buffers go back at once.
final class Capture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let displayID: CGDirectDisplayID
    private let configuration = SCStreamConfiguration()
    private let queue = DispatchQueue(label: "kosmos-probe.bench-frames", qos: .userInteractive)
    private let frame: @Sendable (Picture) -> Void
    private let failed: @Sendable (String) -> Void
    /// Held so the stream runs.
    private var stream: SCStream?
    private let ticks: Double

    init(displayID: CGDirectDisplayID, area: CGRect, width: Int, height: Int, rate: Int,
         frame: @escaping @Sendable (Picture) -> Void, failed: @escaping @Sendable (String) -> Void) {
        self.displayID = displayID
        self.frame = frame
        self.failed = failed
        var timebase = mach_timebase_info()
        mach_timebase_info(&timebase)
        ticks = Double(timebase.numer) / Double(timebase.denom) / 1e9
        configuration.sourceRect = area
        configuration.width = width
        configuration.height = height
        // The shortest time ScreenCaptureKit leaves between frames. At half a refresh it cannot
        // drop a refresh that comes a little early, as a whole refresh could.
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(2 * max(rate, 1)))
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.showsCursor = false
        configuration.queueDepth = 8
        super.init()
    }

    func start() {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
            guard let display = content?.displays.first(where: { $0.displayID == self.displayID }) else {
                return self.failed("no shareable built-in display: \(error.map { "\($0)" } ?? "not listed")")
            }
            let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: self.configuration, delegate: self)
            do {
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue)
            } catch {
                return self.failed("\(error)")
            }
            self.stream = stream
            stream.startCapture { error in if let error { self.failed("\(error)") } }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, buffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first, let status = (info[.status] as? Int).flatMap(SCFrameStatus.init),
              // The first frame after the start comes as started, and each later one with news
              // as complete; an unchanged display sends idle ones with no image.
              status == .complete || status == .started,
              let displayTime = info[.displayTime] as? UInt64, let pixels = CMSampleBufferGetImageBuffer(buffer) else { return }
        // The display time is mach absolute time; the offset to the wall clock is taken now, so
        // the two clocks cannot drift apart over the run.
        let now = Date().timeIntervalSince1970
        let time = Double(displayTime) * ticks + now - Double(mach_absolute_time()) * ticks
        // The first frame is let through: whether its display time is its capture's or the
        // display's last change, which can be long before, is unmeasured.
        guard status == .started || abs(time - now) < 1 else {
            return failed(String(format: "a frame's display time is %.3f s from now", time - now))
        }
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels), stride = CVPixelBufferGetBytesPerRow(pixels)
        guard let base = CVPixelBufferGetBaseAddress(pixels) else { return }
        var copy = [UInt32](repeating: 0, count: width * height)
        copy.withUnsafeMutableBytes { target in
            for row in 0..<height { memcpy(target.baseAddress! + row * width * 4, base + row * stride, width * 4) }
        }
        let picture = Picture(width: width, height: height, pixels: copy, time: time)
        frame(picture)
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        failed("the stream stopped: \(error)")
    }
}
