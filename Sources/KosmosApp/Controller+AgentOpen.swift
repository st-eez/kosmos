import AppKit
import KosmosCore
import KosmosIPC

/// An app an agent opened with `kosmos open`: its new windows until `until` go to the agent
/// workspace (docs/displays.md).
struct AgentClaim {
    var until: ContinuousClock.Instant
    /// Those its claims sent to the agent workspace, and when, kept while claims follow each
    /// other, as each `kosmos open` reports those since its own.
    var windows: [(id: WindowID, at: ContinuousClock.Instant)] = []
}

extension Controller {
    func claim(_ app: String) {
        let now = ContinuousClock.now
        let windows = agentClaims[app].flatMap { now < $0.until ? $0.windows : nil } ?? []
        agentClaims[app] = AgentClaim(until: now + .seconds(10), windows: windows)
    }

    /// `kosmos open`'s request once `open` returns, `elapsed` after its claim: where what it
    /// opened landed. A running app's new window came 0.5 to 1.6 s after the claim, two of
    /// them in one ms (2026-10-08); a launch can take the claim's 10 s. A tab in a window the
    /// app has costs the whole 3 s; watching its windows' titles would end the wait at the tab.
    /// Two opens of one app at once cannot tell their windows apart (docs/ipc.md).
    func opened(_ app: String, elapsed: Duration) async -> Response {
        let since = ContinuousClock.now - elapsed
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: app).first
        let launchedBefore = running?.launchDate.map { $0 < Date.now - elapsed.timeInterval } == true
        let waited: Duration = launchedBefore ? .seconds(3) : .seconds(10)
        func mine() -> [WindowID] { agentClaims[app]?.windows.filter { $0.at >= since && owner[$0.id] != nil }.map(\.id) ?? [] }
        var settled: ContinuousClock.Instant?
        while true {
            if settled == nil, !mine().isEmpty { settled = .now + .milliseconds(500) }
            if ContinuousClock.now >= settled ?? since + waited { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        let name = NSRunningApplication.runningApplications(withBundleIdentifier: app).first?.localizedName ?? app
        if !mine().isEmpty { return Response(stdout: AgentOpenReport.new(app: name, windows: mine()).sentence) }
        // A tab its group does not show has an owner and no workspace (docs/tree.md).
        let had = owner.keys.filter { id in
            session.workspace(of: id) != nil && owner[id].map { inventory.appIdentity($0).bundleID == app } == true
        }
        guard let window = mostRecent(had.sorted()), let workspace = session.workspace(of: window) else {
            return Response(stdout: AgentOpenReport.unknown(app: name, waited: waited).sentence)
        }
        return Response(stdout: AgentOpenReport.existing(app: name, window: window, count: had.count, workspace: workspace).sentence)
    }
}

private extension Duration {
    var timeInterval: TimeInterval { Double(components.seconds) + Double(components.attoseconds) * 1e-18 }
}
