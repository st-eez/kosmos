import CoreGraphics
import Foundation
import ImageIO

/// The capture's side of script/bench-frames.sh: takes the frames as they arrive and the
/// script's lines, measures each step, and writes the run's tables and pictures. The protocol
/// is in the header of kosmos-probe's Frames.swift.
@MainActor public final class Recorder {
    public static let leastFree: Int64 = 20 << 30
    public static let mostOutput: Int64 = 500 << 20
    /// Pictures stop here, so the tables still fit.
    public static let mostPictures: Int64 = 400 << 20
    public static let picturesPerStep = 6
    /// A screen still changing this long after a step asks for it still is taken as it is.
    public static let longestWait = 5.0

    public private(set) var finished = false
    private let directory: URL
    private let display: String
    private var scene: Scene
    private let reply: (String) -> Void
    private var screen = Screen()
    private var delivered = 0
    private var waiting: Waiting?
    private var step: (number: Int, rep: Int, expect: Expect, action: String)?
    private var sent: (at: Double, answered: Double, exit: String)?
    private var records: [Record] = []
    private var files: [String: FileHandle] = [:]

    private enum Waiting {
        case still(since: Double, then: () -> Void)
        case settle(sent: Double)
    }

    public init(directory: URL, display: String, refresh: Double, real: Bool, reply: @escaping (String) -> Void) {
        self.directory = directory
        self.display = display
        self.reply = reply
        scene = Scene(palette: .stub, wallpaper: nil, refresh: refresh, real: real)
        write("frames.tsv", "step\tframe\ttime\tms\tchanged\tfrom before\tfrom after\tneither\tflagged\n")
        write("tracks.tsv", "step\twindow\tframe\tms\tprogress\teased\tmisfit\n")
        write("events.tsv", "step\tframe\tms\tkind\twhat\tdetail\tpicture\n")
        write("steps.tsv", "step\trep\taction\texpect\tsent\tanswered\texit\tsettle\tlatency\tframes\tspan\tslide start\twindows\tborder\t"
            + "key\tstalls\tjumps\tdisplaced\tflashes\n")
    }

    public func add(_ picture: Picture) {
        delivered += 1
        screen.add(picture)
    }

    public func command(_ line: String, at now: Double) {
        let words = line.split(separator: " ").map(String.init)
        switch words.first {
        case "wallpaper":
            wait(at: now) {
                guard let latest = self.screen.latest else { return self.abort("no frame came from the capture") }
                self.scene.wallpaper = latest
                self.reply("ok")
            }
        case "step" where words.count >= 5:
            guard let number = Int(words[1]), let rep = Int(words[2]), let expect = Expect(rawValue: words[3]) else {
                return abort("cannot read \(line)")
            }
            guard roomLeft() else { return }
            wait(at: now) {
                if let latest = self.screen.latest { self.scene.palette = self.scene.palette.calibrated(from: latest) }
                self.step = (number, rep, expect, words[4...].joined(separator: " "))
                self.screen.arm()
                self.reply("armed \(number)")
            }
        case "sent" where words.count == 5:
            guard let at = Double(words[2]), step != nil, step?.number == Int(words[1]) else { return abort("cannot read \(line)") }
            sent = (at, Double(words[3]) ?? at, words[4])
            waiting = .settle(sent: at)
            check(at: now)
        case "end":
            finish()
        default:
            abort("cannot read \(line)")
        }
    }

    private func wait(at now: Double, then: @escaping () -> Void) {
        waiting = .still(since: now, then: then)
        check(at: now)
    }

    public func check(at now: Double) {
        switch waiting {
        case let .still(since, then):
            guard screen.isQuiet(at: now) || now - since > Self.longestWait else { return }
            waiting = nil
            then()
        case let .settle(at):
            guard let settle = screen.settled(sent: at, at: now) else { return }
            waiting = nil
            measure(settle)
        case nil:
            break
        }
    }

    private func measure(_ settle: Screen.Settle) {
        guard let step, let sent, let (before, frames) = screen.take(sent: sent.at) else { return abort("no frames") }
        let analysis = analyze(step.expect, sent: sent.at, before: before, frames: frames, scene: scene)
        let record = Record(number: step.number, rep: step.rep, action: step.action, expect: step.expect, sent: sent.at,
                            settle: settle, analysis: analysis)
        records.append(record)
        let ms = { (time: Double) in String(format: "%.2f", (time - sent.at) * 1000) }
        for row in analysis.rows {
            write("frames.tsv", "\(step.number)\t\(row.frame)\t\(String(format: "%.6f", row.time))\t\(ms(row.time))\t\(row.changed)\t"
                + "\(row.fromBefore)\t\(row.fromAfter)\t\(row.neither)\t\(row.flagged)\n")
        }
        for track in analysis.tracks {
            for sample in track.samples {
                let eased = track.predicted(at: sample.time).map { String(format: "%.4f", $0) } ?? "-"
                write("tracks.tsv", "\(step.number)\t\(track.window.map(String.init) ?? "real")\t\(sample.frame)\t\(ms(sample.time))\t"
                    + String(format: "%.4f", sample.progress) + "\t\(eased)\t\(sample.misfit)\n")
            }
        }
        var pictures = 0
        for event in analysis.events {
            var file = "-"
            if pictures < Self.picturesPerStep, outputBytes() < Self.mostPictures {
                if pictures == 0 {
                    save(before, as: String(format: "step-%04d-before.png", step.number))
                    save(frames.last!, as: String(format: "step-%04d-after.png", step.number))
                }
                file = String(format: "step-%04d-frame-%03d-%@.png", step.number, event.frame, event.kind.rawValue)
                save(frames[event.frame], marking: event.pixels, expected: event.expected, shown: event.shown, as: file)
                pictures += 1
            }
            write("events.tsv", "\(step.number)\t\(event.frame)\t\(ms(frames[event.frame].time))\t\(event.kind.rawValue)\t"
                + "\(event.what)\t\(event.detail)\t\(file)\n")
        }
        func number(_ value: Double?) -> String { value.map { String(format: "%.2f", $0) } ?? "-" }
        write("steps.tsv", "\(step.number)\t\(step.rep)\t\(step.action)\t\(step.expect.rawValue)\t\(String(format: "%.6f", sent.at))\t"
            + "\(String(format: "%.6f", sent.answered))\t\(sent.exit)\t\(settle.rawValue)\t\(number(analysis.latency))\t"
            + "\(analysis.frames)\t\(number(analysis.span))\t\(number(analysis.began))\t\(number(analysis.windows))\t"
            + "\(number(analysis.border))\t\(number(analysis.keyed))\t\(record.stalls.count)\t\(record.jumps.count)\t"
            + "\(record.displaced.count)\t\(record.flashes.count)\n")
        (self.step, self.sent) = (nil, nil)
        guard roomLeft() else { return }
        reply("done \(step.number) \(number(analysis.latency)) \(analysis.frames) \(record.stalls.count) \(record.jumps.count) "
            + "\(record.displaced.count) \(record.flashes.count) \(settle.rawValue)")
    }

    /// Writes table.txt and kosmos-steps.txt, with Kosmos's log lines from each step's send to
    /// the next step's, which kosmos.log holds once the script has stopped its `log stream`.
    public func finish() {
        guard !finished else { return }
        finished = true
        let log = (try? String(contentsOf: directory.appendingPathComponent("kosmos.log"), encoding: .utf8)) ?? ""
        let lines = log.split(separator: "\n").compactMap { LogLine($0) }
        for index in records.indices {
            let from = records[index].sent - 0.001
            let to = index + 1 < records.count ? records[index + 1].sent - 0.001 : .infinity
            records[index].log = lines.filter { $0.time >= from && $0.time < to }
        }
        // The stub names each window's color as it opens it, and a color goes to a new window
        // once its window closes.
        let stub = (try? String(contentsOf: directory.appendingPathComponent("stub.out"), encoding: .utf8)) ?? ""
        let colors = stub.split(separator: "\n").compactMap { line -> (time: Double, index: Int, id: String)? in
            let words = line.split(separator: " ")
            guard words.count == 4, words[0] == "color", let index = Int(words[2]), let time = Double(words[3]) else { return nil }
            return (time, index, String(words[1]))
        }
        var steps = "", named = ""
        for record in records {
            let analysis = record.analysis
            var legend: [Int: String] = [:]
            for color in colors where color.time <= record.sent { legend[color.index] = color.id }
            let names = legend.sorted { $0.key < $1.key }.map { "window \($0.key) is \($0.value)" }.joined(separator: ", ")
            if names != named {
                steps += "stub windows by color: \(names)\n"
                named = names
            }
            steps += "step \(record.number), rep \(record.rep), \(record.action): "
            steps += analysis.latency.map { String(format: "first change %.1f ms after the send, %d frames over %.1f ms", $0, analysis.frames, analysis.span) }
                ?? "no change"
            steps += ", \(record.settle.rawValue)\n"
            for event in analysis.events {
                let at = analysis.rows[event.frame].time
                steps += String(format: "  frame %d at %+.1f ms: %@ %@\n", event.frame, (at - record.sent) * 1000, event.kind.rawValue, event.detail)
                // What Kosmos logged while a window stood still, and about a window off its way.
                let related = if event.kind == .stall, let since = event.since {
                    record.log.filter { $0.time >= since - 0.002 && $0.time <= at + 0.002 }
                } else if let window = event.window, let id = legend[window] {
                    record.log.filter { $0.message.hasPrefix("\(id) ") }
                } else {
                    [LogLine]()
                }
                for line in related {
                    steps += String(format: "      %+8.1f ms  %@: %@\n", (line.time - record.sent) * 1000, line.category, line.message)
                }
            }
            for line in record.log {
                steps += String(format: "    %+8.1f ms  %@: %@\n", (line.time - record.sent) * 1000, line.category, line.message)
            }
        }
        write("kosmos-steps.txt", steps)
        let kept = records.reduce(0) { $0 + $1.analysis.frames }
        let intervals = records.filter { $0.expect == .slide }.flatMap { record in
            zip(record.analysis.rows, record.analysis.rows.dropFirst()).map { ($1.time - $0.time) * 1000 }
        }
        var tally: [String: Int] = [:]
        for event in records.flatMap(\.analysis.events) { tally["\(event.kind.rawValue) \(event.what)", default: 0] += 1 }
        let median = percentile(intervals, 0.5).map { String(format: "%.1f", $0) } ?? "-"
        var table = summary(records) + "\n\n"
        table += "\(display) at \(Int((1 / scene.refresh).rounded())) Hz, captured at 2 points a pixel: \(delivered) frames delivered, "
        table += "\(kept) kept as changes, \(median) ms apart at the median in slides\n"
        table += "events: " + (tally.isEmpty ? "none" : tally.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .map { "\($0.value) \($0.key)" }.joined(separator: ", ")) + "\n"
        write("table.txt", table)
        files.values.forEach { try? $0.close() }
        reply("end")
    }

    public func abort(_ why: String) {
        guard !finished else { return }
        reply("abort \(why)")
        finish()
    }

    private func roomLeft() -> Bool {
        var stats = statfs()
        if statfs(directory.path, &stats) == 0, Int64(stats.f_bavail) * Int64(stats.f_bsize) < Self.leastFree {
            abort("free disk under 20 GB")
            return false
        }
        if outputBytes() > Self.mostOutput {
            abort("\(directory.path) passed 500 MB")
            return false
        }
        return true
    }

    private func outputBytes() -> Int64 {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.reduce(0) { total, name in
            let size = (try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(name).path)[.size]) as? NSNumber
            return total + (size?.int64Value ?? 0)
        }
    }

    private func write(_ file: String, _ text: String) {
        if files[file] == nil {
            let url = directory.appendingPathComponent(file)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            files[file] = try? FileHandle(forWritingTo: url)
        }
        files[file]?.write(Data(text.utf8))
    }

    /// The frame with the flagged pixels in a black and white checker, where the easing put the
    /// window in white and where it showed in black.
    private func save(_ picture: Picture, marking: [Int32] = [], expected: CGRect? = nil, shown: CGRect? = nil, as file: String) {
        var picture = picture
        let width = picture.width
        let white: UInt32 = 0xffff_ffff, black: UInt32 = 0xff00_0000
        for index in marking.map(Int.init) { picture.pixels[index] = (index % width + index / width) % 2 == 0 ? white : black }
        let outlines: [(CGRect?, UInt32)] = [(expected, white), (shown, black)]
        for case let (rect?, color) in outlines {
            for edge in [CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 1),
                         CGRect(x: rect.minX, y: rect.maxY - 1, width: rect.width, height: 1),
                         CGRect(x: rect.minX, y: rect.minY, width: 1, height: rect.height),
                         CGRect(x: rect.maxX - 1, y: rect.minY, width: 1, height: rect.height)] {
                picture.fill(edge, with: color)
            }
        }
        let data = picture.pixels.withUnsafeBytes { Data($0) } as CFData
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let provider = CGDataProvider(data: data), let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(width: width, height: picture.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: space, bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithURL(directory.appendingPathComponent(file) as CFURL, "public.png" as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}
