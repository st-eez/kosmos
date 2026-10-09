/// What `kosmos open` says became of what it opened, once `open` returns (docs/ipc.md).
public enum AgentOpenReport: Equatable, Sendable {
    /// Windows its claim sent to the agent workspace.
    case new(app: String, windows: [WindowID])
    /// No new window came, so the app most likely took it in a window it had: the one focused
    /// last, where a browser adds a tab, of the `count` Kosmos places, on its workspace. Most
    /// likely, as the app is the one the file's type names, and a file's own Open With choice
    /// goes unseen (docs/ipc.md).
    case existing(app: String, window: WindowID, count: Int, workspace: String)
    /// No new window came, and the app has none.
    case unknown(app: String, waited: Duration)

    public var sentence: String {
        switch self {
        case .new(let app, let windows):
            windows.count == 1
                ? "opened in a new \(app) window, \(windows[0]), on the agent workspace"
                : "opened in \(windows.count) new \(app) windows on the agent workspace: \(windows.map(String.init).joined(separator: ", "))"
        case .existing(let app, let window, let count, let workspace):
            "no new window came, so \(app) most likely took it into "
                + (count == 1 ? "its window \(window)" : "the last used of its \(count) windows, \(window),")
                + (workspace == Session.agent ? " on the agent workspace" : " on workspace \(workspace), not the agent workspace")
        case .unknown(let app, let waited):
            "no \(app) window came in \(waited.components.seconds) s, and it has none, so where it opened is unknown"
        }
    }
}
