import Foundation

/// One step of the run as the summary needs it.
public struct Record: Sendable {
    public let number: Int
    public let rep: Int
    public let action: String
    public let expect: Expect
    public let sent: Double
    public let settle: Screen.Settle
    public let analysis: Analysis
    /// Kosmos's log from the send to the next step's.
    public var log: [LogLine] = []

    public init(number: Int, rep: Int, action: String, expect: Expect, sent: Double, settle: Screen.Settle, analysis: Analysis) {
        (self.number, self.rep, self.action, self.expect, self.sent, self.settle, self.analysis) =
            (number, rep, action, expect, sent, settle, analysis)
    }

    public var stalls: [Event] { analysis.events.filter { $0.kind == .stall } }
    public var jumps: [Event] { analysis.events.filter { $0.kind == .jump || $0.kind == .backward } }
    /// Frames with a flash, a partial change or a revert.
    public var flashes: [Event] { analysis.events.filter { [.flash, .partial, .revert].contains($0.kind) } }
}

/// Nearest rank, as script/bench-relayout.sh takes them.
public func percentile(_ values: [Double], _ fraction: Double) -> Double? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    return sorted[max(0, Int((Double(sorted.count) * fraction).rounded(.up)) - 1)]
}

/// The summary table: one row per action, in the order the run first took each.
public func summary(_ records: [Record]) -> String {
    var actions: [String] = []
    for record in records where !actions.contains(record.action) { actions.append(record.action) }
    func cell(_ values: [Double], _ format: String = "%.1f") -> String {
        guard let median = percentile(values, 0.5), let p95 = percentile(values, 0.95) else { return "-" }
        return String(format: "\(format)/\(format)", median, p95)
    }
    func share(_ count: Int, _ total: Int) -> String { count == 0 ? "0" : "\(count)/\(total)" }
    func counted(_ count: Int, _ what: String) -> String? { count == 0 ? nil : "\(count) \(what)" }
    let header = ["action", "n", "latency ms", "frames", "span ms", "stalls", "longest", "jumps", "flashes", "switch ms",
                  "held ms", "landed ms", "slowest link ms"]
    var rows = [header]
    for action in actions {
        let steps = records.filter { $0.action == action }
        let changed = steps.filter { $0.analysis.latency != nil }
        let facts = steps.map { Facts($0.log) }
        let stalled = steps.filter { !$0.stalls.isEmpty }
        let longest = steps.flatMap(\.stalls).compactMap(\.amount).max()
        var kinds: [String: Int] = [:]
        for event in steps.flatMap(\.flashes) { kinds["\(event.kind.rawValue) \(event.what)", default: 0] += 1 }
        let flashed = steps.filter { !$0.flashes.isEmpty }.count
        let top = kinds.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.first.map { " (\($0.key))" } ?? ""
        rows.append([
            action, ["\(steps.count)", counted(steps.filter { $0.settle == .unchanged }.count, "unchanged"),
                     counted(steps.filter { $0.settle == .cut }.count, "cut")].compactMap { $0 }.joined(separator: ", "),
            cell(changed.compactMap(\.analysis.latency)), cell(changed.map { Double($0.analysis.frames) }, "%.0f"),
            cell(changed.map(\.analysis.span)), share(stalled.count, steps.count), longest.map { String(format: "%.1f", $0) } ?? "-",
            share(steps.filter { !$0.jumps.isEmpty }.count, steps.count), share(flashed, steps.count) + top,
            cell(facts.flatMap(\.switches)), cell(facts.flatMap(\.held)), cell(facts.flatMap(\.landed)),
            facts.compactMap(\.slowestFrame).max().map { String(format: "%.2f", $0) } ?? "-",
        ])
    }
    let widths = header.indices.map { column in rows.map { $0[column].count }.max()! }
    return rows.map { row in
        row.indices.map { row[$0].padding(toLength: widths[$0], withPad: " ", startingAt: 0) }.joined(separator: "  ")
            .trimmingCharacters(in: .whitespaces)
    }.joined(separator: "\n")
}
