/// An app an agent opened with `kosmos open`: its new windows until `until` go to the agent
/// workspace (docs/displays.md).
public struct AgentClaim: Sendable {
    public let until: ContinuousClock.Instant
    /// The windows there when the claim began, which `open` cannot have made, as `kosmos open`
    /// claims before it runs `open` (docs/ipc.md).
    public let before: Set<WindowID>
    /// Those its claims sent to the agent workspace, and when, kept while claims follow each
    /// other, as each `kosmos open` reports those since its own.
    public var windows: [(id: WindowID, at: ContinuousClock.Instant)]

    /// A claim made while `current` runs keeps its windows and what was there before it.
    public init(over current: AgentClaim?, before there: Set<WindowID>, at now: ContinuousClock.Instant) {
        let running = current?.running(at: now)
        until = now + .seconds(10)
        before = running?.before ?? there
        windows = running?.windows ?? []
    }

    public func running(at now: ContinuousClock.Instant) -> AgentClaim? {
        now < until ? self : nil
    }

    /// Whether the claim takes a window admitted while it runs. A window its app closed and
    /// kept and orders in again was there before, and opens as a new one does (docs/tree.md).
    public func takes(_ id: WindowID, reopened: Bool) -> Bool {
        reopened || !before.contains(id)
    }
}
