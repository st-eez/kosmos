/// A line and column in a config file, both counted from 1. Columns count Unicode scalars.
/// `file` is 0 in the main file and n in the nth file it includes.
public struct SourcePosition: Hashable, Comparable, Sendable {
    public var line: Int
    public var column: Int
    public var file: Int

    public init(line: Int, column: Int, file: Int = 0) {
        self.line = line
        self.column = column
        self.file = file
    }

    public static func < (a: Self, b: Self) -> Bool {
        (a.file, a.line, a.column) < (b.file, b.line, b.column)
    }
}

/// `description` reads like a compiler message, `12:5: error: gaps.inner: ...`, so a caller
/// prints it after the file name and a colon.
public struct Diagnostic: Error, Equatable, Sendable, CustomStringConvertible {
    public enum Severity: String, Sendable {
        case error
        case warning
    }

    public var severity: Severity
    public var position: SourcePosition
    /// The key the problem is about, such as `mode.main.binding.alt-h` or `rule[2].workspace`.
    /// Empty when the problem is outside any key.
    public var path: String
    public var message: String
    /// The included file the problem is in, as the main file's `include` names it, or nil
    /// for the main file.
    public var file: String?

    public init(_ severity: Severity, at position: SourcePosition, path: String, _ message: String) {
        self.severity = severity
        self.position = position
        self.path = path
        self.message = message
    }

    public var description: String {
        let location = "\(position.line):\(position.column): \(severity.rawValue): "
        return path.isEmpty ? location + message : location + path + ": " + message
    }
}

/// A key path as TOML writes it: bare keys joined by dots, other keys quoted, and array
/// elements as `[index]`, counted from 0.
struct ValuePath: CustomStringConvertible {
    private(set) var description = ""

    func key(_ name: String) -> ValuePath {
        let isBare = !name.isEmpty && name.unicodeScalars.allSatisfy(isBareKeyScalar)
        let part = isBare ? name : "\"" + name.replacing("\\", with: "\\\\").replacing("\"", with: "\\\"") + "\""
        return ValuePath(description: description.isEmpty ? part : description + "." + part)
    }

    func index(_ index: Int) -> ValuePath {
        ValuePath(description: description + "[\(index)]")
    }
}

func isBareKeyScalar(_ c: Unicode.Scalar) -> Bool {
    switch c {
    case "A"..."Z", "a"..."z", "0"..."9", "_", "-": true
    default: false
    }
}

/// "; did you mean 'x'?" for the candidate closest to `word`, or an empty string when none is
/// close. Ties go to the alphabetically first candidate, so the message is stable.
func suggestion(for word: String, from candidates: some Sequence<String>) -> String {
    let scored = candidates.map { ($0, editDistance(word.lowercased(), $0.lowercased())) }
    guard let (best, distance) = scored.min(by: { ($0.1, $0.0) < ($1.1, $1.0) }),
          distance <= max(2, word.count / 3), distance < word.count
    else { return "" }
    return "; did you mean '\(best)'?"
}

/// The optimal string alignment distance, which counts a swap of neighbors as one edit, so
/// `ecs` is one edit from `esc`.
func editDistance(_ a: String, _ b: String) -> Int {
    let a = Array(a), b = Array(b)
    var rows = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
    for i in 0...a.count { rows[i][0] = i }
    for j in 0...b.count { rows[0][j] = j }
    for i in a.indices {
        for j in b.indices {
            var distance = min(rows[i][j + 1] + 1, rows[i + 1][j] + 1, rows[i][j] + (a[i] == b[j] ? 0 : 1))
            if i > 0, j > 0, a[i] == b[j - 1], a[i - 1] == b[j] {
                distance = min(distance, rows[i - 1][j - 1] + 1)
            }
            rows[i + 1][j + 1] = distance
        }
    }
    return rows[a.count][b.count]
}
