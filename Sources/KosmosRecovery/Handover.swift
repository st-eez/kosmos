/// `kosmos handover [record version]`, for script/install.sh: a quit within `life` of the arm
/// leaves the record to a Kosmos that starts right after it, which reads that version, this
/// build's when none is given. A refusal disarms (docs/hiding.md).
public struct Handover: Sendable {
    /// script/install.sh sends its SIGTERM right after the arm, 2 to 7 ms after it at three
    /// installs (docs/hiding.md).
    public static let life: Duration = .seconds(5)

    private var armedAt: ContinuousClock.Instant?

    public init() {}

    /// Nil once armed, or else why not. `hiding`: whether Kosmos has started to manage windows,
    /// as it hides none before.
    public mutating func arm(_ arguments: [String], hiding: Bool, at now: ContinuousClock.Instant) -> String? {
        armedAt = nil
        let version = arguments.isEmpty ? RecoveryRecord.version : arguments.count == 1 ? UInt32(arguments[0]) : nil
        guard let version else { return "usage: handover [record version]" }
        guard version == RecoveryRecord.version else {
            return "the next Kosmos reads record version \(version) and this one writes \(RecoveryRecord.version), so quitting restores the hidden windows"
        }
        guard hiding else { return "no windows are hidden before Kosmos manages them" }
        armedAt = now
        return nil
    }

    /// Only the quit the arm was for, and only with a guardian to restore the windows should
    /// no Kosmos follow (docs/hiding.md).
    public func handsOver(at now: ContinuousClock.Instant, guardianReady: Bool) -> Bool {
        armedAt.map { now - $0 < Self.life } == true && guardianReady
    }
}
