import Foundation

/// A line of Kosmos's log as `log stream --style compact` prints it:
/// `2026-09-25 12:33:16.316 I  Kosmos[54212:224e5ac] [io.github.st-eez.kosmos:slide] 8 of 8 ...`.
public struct LogLine: Sendable {
    /// Seconds since 1970, to the millisecond the log prints.
    public let time: Double
    public let category: String
    public let message: String

    public init?(_ line: Substring, calendar: Calendar = .current) {
        let marker = "[io.github.st-eez.kosmos:"
        guard line.count > 23, let open = line.range(of: marker), let close = line[open.upperBound...].firstIndex(of: "]") else {
            return nil
        }
        let digits = Array(line.prefix(23))
        func number(_ range: Range<Int>) -> Int? { Int(String(digits[range])) }
        guard let year = number(0..<4), let month = number(5..<7), let day = number(8..<10), let hour = number(11..<13),
              let minute = number(14..<16), let second = number(17..<19), let milliseconds = number(20..<23),
              let date = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))
        else { return nil }
        time = date.timeIntervalSince1970 + Double(milliseconds) / 1000
        category = String(line[open.upperBound..<close])
        message = String(line[line.index(after: close)...].drop { $0 == " " })
    }

    /// Whether the line is about the window: it starts with the window's id, or it is a display
    /// frame's line that says where the window shows.
    public func isAbout(_ window: String) -> Bool {
        message.hasPrefix("\(window) ") || message.contains("; \(window) shown at ")
    }
}

/// What Kosmos logged about one step: its switches, slides, writes and display link frames.
public struct Facts: Sendable {
    /// Milliseconds: each switch's total from its command to its batch confirmed, and the
    /// wait for writes to land before its batch went.
    public var switches: [Double] = []
    public var held: [Double] = []
    /// Milliseconds from each slide's write to its landing.
    public var landed: [Double] = []
    public var slid = 0, popped = 0, unlanded = 0, ended = 0, jumped = 0
    /// Milliseconds each switch's batch completion held the main actor: its bridge time less
    /// the parts the line names.
    public var completions: [Double] = []
    /// Display frames each slide and pop stepped, about 46 over 0.38 s at 120 Hz.
    public var stepped: [Int] = []
    /// Milliseconds between the reads that follow a landing write, each run's time over its
    /// reads.
    public var readGaps: [Double] = []
    /// WindowServer's Space membership events, from the inventory's debug lines.
    public var memberships = 0
    /// Milliseconds: the slowest display link callback, and the slowest Accessibility write.
    public var slowestFrame: Double?
    public var slowestWrite: Double?
    public var failed = 0

    public init(_ lines: [LogLine]) {
        for line in lines {
            let message = line.message
            if let match = message.firstMatch(of: #/^switch to \S+: .*total ([0-9.]+) ms, (\w+)/#) {
                switches.append(Double(match.1)!)
                if match.2 != "confirmed" { failed += 1 }
                if let wait = message.firstMatch(of: #/held ([0-9.]+) ms/#) { held.append(Double(wait.1)!) }
                let parts = #/bridge ([0-9.]+) ms \(queued ([0-9.]+), sent ([0-9.]+), confirmed ([0-9.]+)[^,]*, recovered ([0-9.]+), back ([0-9.]+)\)/#
                if let bridge = message.firstMatch(of: parts) {
                    let values = [bridge.1, bridge.2, bridge.3, bridge.4, bridge.5, bridge.6].map { Double($0)! }
                    completions.append(max(0, values[0] - values.dropFirst().reduce(0, +)))
                }
            } else if let match = message.firstMatch(of: #/^\d+ (slid|popped) in (\d+) frames, (?:landed ([0-9.]+) ms|did not land)/#) {
                if match.1 == "popped" { popped += 1 } else { slid += 1 }
                stepped.append(Int(match.2)!)
                if let ms = match.3 { landed.append(Double(ms)!) } else { unlanded += 1 }
            } else if message.firstMatch(of: #/^\d+ slide ended /#) != nil {
                ended += 1
            } else if let match = message.firstMatch(of: #/^relayout: .*, (\d+) jump/#) {
                jumped += Int(match.1)!
            } else if let match = message.firstMatch(of: #/^slide frames: \d+ callbacks, [0-9.]+ ms in them, ([0-9.]+) ms at most/#) {
                slowestFrame = max(slowestFrame ?? 0, Double(match.1)!)
            } else if let match = message.firstMatch(of: #/^\d+ written, AX time ([0-9.]+) ms/#) {
                slowestWrite = max(slowestWrite ?? 0, Double(match.1)!)
            } else if let match = message.firstMatch(of: #/^slide reads: (\d+), \d+ of them 0\.1 ms apart, over ([0-9.]+) ms/#),
                      let reads = Double(match.1), reads > 0 {
                readGaps.append(Double(match.2)! / reads)
            } else if message.hasPrefix("event spaceMembership(") {
                memberships += 1
            }
        }
    }
}
