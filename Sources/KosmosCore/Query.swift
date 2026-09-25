/// A CLI request that reads Kosmos's state and changes nothing. Any other request is a
/// `Command` (docs/ipc.md).
public enum Query: String, Sendable {
    case ping
    case version
    case state
    case listWorkspaces = "list-workspaces"
    case listWindows = "list-windows"
    case listBindings = "list-bindings"

    /// Nil when the arguments are no query.
    public init?(_ arguments: [String]) {
        guard arguments.count == 1 else { return nil }
        self.init(rawValue: arguments[0])
    }
}
