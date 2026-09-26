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
    /// Kosmos's log from the send to the settle.
    public var log: [LogLine] = []
    /// When the screen had settled, so what comes after it belongs to no step.
    public var end = Double.infinity

    public init(number: Int, rep: Int, action: String, expect: Expect, sent: Double, settle: Screen.Settle, analysis: Analysis) {
        (self.number, self.rep, self.action, self.expect, self.sent, self.settle, self.analysis) =
            (number, rep, action, expect, sent, settle, analysis)
    }

    public var stalls: [Event] { analysis.events.filter { $0.kind == .stall } }
    public var jumps: [Event] { analysis.events.filter { $0.kind == .jump || $0.kind == .backward } }
    public var displaced: [Event] { analysis.events.filter { $0.kind == .displaced } }
    /// Frames with a flash, a partial change or a revert.
    public var flashes: [Event] { analysis.events.filter { [.flash, .partial, .revert].contains($0.kind) } }
}

/// Nearest rank, as script/bench-relayout.sh takes them.
public func percentile(_ values: [Double], _ fraction: Double) -> Double? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    return sorted[max(0, Int((Double(sorted.count) * fraction).rounded(.up)) - 1)]
}

/// The summary: per action, in the order the run first took each, what the screen showed,
/// then what Kosmos logged.
public func summary(_ records: [Record]) -> String {
    var actions: [String] = []
    for record in records where !actions.contains(record.action) { actions.append(record.action) }
    func cell(_ values: [Double], _ format: String = "%.1f") -> String {
        guard let median = percentile(values, 0.5), let p95 = percentile(values, 0.95) else { return "-" }
        return String(format: "\(format)/\(format)", median, p95)
    }
    func share(_ steps: [Record], _ events: (Record) -> [Event]) -> String {
        let count = steps.filter { !events($0).isEmpty }.count
        return count == 0 ? "0" : "\(count)/\(steps.count)"
    }
    func counted(_ count: Int, _ what: String) -> String? { count == 0 ? nil : "\(count) \(what)" }
    var screen = [["action", "n", "latency ms", "frames", "span ms", "windows ms", "border ms", "key ms", "stalls", "longest ms",
                   "jumps", "displaced", "flashes"]]
    var log = [["action", "switch ms", "held ms", "completion ms", "landed ms", "stepped", "read gap ms", "slowest link ms",
                "membership events"]]
    for action in actions {
        let steps = records.filter { $0.action == action }
        let changed = steps.filter { $0.analysis.latency != nil }
        var kinds: [String: Int] = [:]
        for event in steps.flatMap(\.flashes) { kinds["\(event.kind.rawValue) \(event.what)", default: 0] += 1 }
        let top = kinds.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.first.map { " (\($0.key))" } ?? ""
        screen.append([
            action, ["\(steps.count)", counted(steps.filter { $0.settle == .unchanged }.count, "unchanged"),
                     counted(steps.filter { $0.settle == .cut }.count, "cut")].compactMap { $0 }.joined(separator: ", "),
            cell(changed.compactMap(\.analysis.latency)), cell(changed.map { Double($0.analysis.frames) }, "%.0f"),
            cell(changed.map(\.analysis.span)), cell(steps.compactMap(\.analysis.windows)), cell(steps.compactMap(\.analysis.border)),
            cell(steps.compactMap(\.analysis.keyed)), share(steps, \.stalls),
            steps.flatMap(\.stalls).compactMap(\.amount).max().map { String(format: "%.1f", $0) } ?? "-",
            share(steps, \.jumps), share(steps, \.displaced), share(steps, \.flashes) + top,
        ])
        let facts = steps.map { Facts($0.log) }
        let stepped = facts.flatMap(\.stepped)
        let short = stepped.filter { $0 < 40 }.count
        log.append([
            action, cell(facts.flatMap(\.switches)), cell(facts.flatMap(\.held)), cell(facts.flatMap(\.completions), "%.2f"),
            cell(facts.flatMap(\.landed)), cell(stepped.map(Double.init), "%.0f") + (short > 0 ? ", \(short) under 40" : ""),
            cell(facts.flatMap(\.readGaps), "%.2f"), facts.compactMap(\.slowestFrame).max().map { String(format: "%.2f", $0) } ?? "-",
            String(format: "%.1f a step", Double(facts.reduce(0) { $0 + $1.memberships }) / Double(max(steps.count, 1))),
        ])
    }
    return table(screen) + "\n\n" + table(log)
}

private func table(_ rows: [[String]]) -> String {
    let widths = rows[0].indices.map { column in rows.map { $0[column].count }.max()! }
    return rows.map { row in
        row.indices.map { row[$0].padding(toLength: widths[$0], withPad: " ", startingAt: 0) }.joined(separator: "  ")
            .trimmingCharacters(in: .whitespaces)
    }.joined(separator: "\n")
}
