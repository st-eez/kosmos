/// A CLI request that reads Kosmos's state and changes nothing. Any other request is a
/// `Command` (docs/ipc.md).
public enum Query: String, Sendable {
    case ping
    case version
    case state
    case listWorkspaces = "list-workspaces"
    case listWindows = "list-windows"
    case listBindings = "list-bindings"

    public init?(_ arguments: [String]) {
        guard arguments.count == 1 else { return nil }
        self.init(rawValue: arguments[0])
    }
}

extension Session {
    public var workspaceList: String {
        names.map { $0 == focusedWorkspace ? "\($0) *" : $0 }.joined(separator: "\n")
    }

    public func windowList(app: (WindowID) -> String?) -> String {
        names.flatMap { name in
            windows(of: name).map { id in "\(id) \(name) \(app(id) ?? "?")\(id == focused ? " *" : "")" }
        }.joined(separator: "\n")
    }
}

/// A binding as `list-bindings` lists it (docs/integrations.md).
public struct ListedBinding: Encodable, Equatable, Sendable {
    public var mode: String
    public var key: String
    public var description: String
    public var category: String

    public static func list(_ modes: [String: [Binding]]) -> [ListedBinding] {
        let modes = modes.sorted { ($0.key == "main" ? 0 : 1, $0.key) < ($1.key == "main" ? 0 : 1, $1.key) }
        return modes.flatMap { mode, bindings in
            bindings.map { ListedBinding(mode: mode, key: $0.key, description: $0.command.summary, category: $0.command.category) }
        }
    }
}
