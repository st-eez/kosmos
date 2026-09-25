/// A binding as `kosmos list-bindings` prints it (DESIGN.md, section 5.12). The app fills
/// these from its loaded config.
public struct ListedBinding: Equatable, Sendable {
    public var mode: String
    /// The combination as the config writes it, such as `alt-shift-left`.
    public var key: String
    /// The command's words, as the CLI takes them.
    public var command: String
    /// A short description for people, such as "Focus left, across monitors".
    public var description: String
    /// A group for launchers, such as Focus or Workspace.
    public var category: String

    public init(mode: String, key: String, command: String, description: String, category: String) {
        self.mode = mode
        self.key = key
        self.command = command
        self.description = description
        self.category = category
    }
}

/// The answer to `list-bindings [--json]`. Plain, each mode gets a line with its name, then one
/// line per binding with the key and the description, the descriptions aligned. With `--json`,
/// one array of objects with the fields of `ListedBinding`, in the same order.
public func listBindings(_ arguments: [String], _ bindings: [ListedBinding]) -> Response {
    switch arguments.dropFirst() {
    case []:
        let width = bindings.map(\.key.count).max() ?? 0
        var lines: [String] = []
        var mode: String?
        for binding in bindings {
            if binding.mode != mode {
                if mode != nil { lines.append("") }
                lines.append("mode \(binding.mode)")
                mode = binding.mode
            }
            lines.append("  " + binding.key + String(repeating: " ", count: width - binding.key.count + 2) + binding.description)
        }
        return Response(stdout: lines.joined(separator: "\n"))
    case ["--json"]:
        let json = JSON.array(bindings.map { binding in
            .object(["mode": .string(binding.mode), "key": .string(binding.key), "command": .string(binding.command),
                     "description": .string(binding.description), "category": .string(binding.category)])
        })
        return Response(stdout: String(decoding: json.encoded, as: UTF8.self))
    default:
        return Response(exitCode: 1, stderr: "kosmos: usage: list-bindings [--json]")
    }
}
