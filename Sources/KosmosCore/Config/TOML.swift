// A TOML 1.1 reader kept to what the schema uses. Ceiling: infinity, nan, dates, multi-line
// strings and non-decimal integers fail; one a key needs is a branch in `value()` (docs/config.md).

struct TOMLValue: Equatable {
    enum Kind: Equatable {
        case string(String)
        case integer(Int)
        case float(Double)
        case boolean(Bool)
        case array([TOMLValue])
        case table(TOMLTable)
    }

    var kind: Kind
    var position: SourcePosition
}

/// A table's entries in file order.
struct TOMLTable: Equatable {
    struct Entry: Equatable {
        var key: String
        var keyPosition: SourcePosition
        var value: TOMLValue
    }

    var entries: [Entry] = []

    subscript(key: String) -> Entry? {
        entries.first { $0.key == key }
    }
}

/// Throws the first syntax error. `file` goes into every position (SourcePosition).
func parseTOML(_ text: String, file: Int = 0) throws(Diagnostic) -> TOMLTable {
    var parser = TOMLParser(text, file: file)
    return try parser.document()
}

/// TOML forbids defining a table twice, and what counts as a definition depends on how the
/// table came to exist, so each table records its origin.
private final class TableBuilder {
    enum Origin {
        /// Named as a prefix of a `[header]`. A later header may still define it.
        case implicit
        /// Defined by a `[header]` or `[[header]]`.
        case header
        /// Created by a dotted key such as `a.b = 1`. Only more dotted keys may extend it.
        case dotted
        /// An inline table `{ ... }`. Nothing adds to it after its closing brace.
        case inline
    }

    enum Slot {
        case value(TOMLValue)
        case table(TableBuilder)
        /// An array of tables, one per `[[header]]`.
        case tables([TableBuilder])
    }

    struct Entry {
        let key: String
        let keyPosition: SourcePosition
        var slot: Slot
    }

    var origin: Origin
    var position: SourcePosition
    private var entries: [Entry] = []
    private var index: [String: Int] = [:]

    init(_ origin: Origin, at position: SourcePosition) {
        self.origin = origin
        self.position = position
    }

    subscript(key: String) -> Entry? {
        index[key].map { entries[$0] }
    }

    func add(_ key: String, at position: SourcePosition, _ slot: Slot) {
        index[key] = entries.count
        entries.append(Entry(key: key, keyPosition: position, slot: slot))
    }

    func replace(_ key: String, with slot: Slot) {
        entries[index[key]!].slot = slot
    }

    func freeze() -> TOMLTable {
        TOMLTable(entries: entries.map { entry in
            let value = switch entry.slot {
            case .value(let value): value
            case .table(let table): TOMLValue(kind: .table(table.freeze()), position: table.position)
            case .tables(let tables):
                TOMLValue(kind: .array(tables.map { TOMLValue(kind: .table($0.freeze()), position: $0.position) }),
                          position: entry.keyPosition)
            }
            return TOMLTable.Entry(key: entry.key, keyPosition: entry.keyPosition, value: value)
        })
    }
}

private struct TOMLParser {
    private let text: [Unicode.Scalar]
    private var i = 0
    private var line = 1
    private var lineStart = 0
    private let file: Int
    /// The key being read, for diagnostics.
    private var path = ValuePath()

    init(_ text: String, file: Int) {
        self.file = file
        self.text = Array(text.unicodeScalars)
        if self.text.first == "\u{FEFF}" {
            i = 1
            lineStart = 1
        }
    }

    mutating func document() throws(Diagnostic) -> TOMLTable {
        let root = TableBuilder(.header, at: position)
        var table = root
        var tablePath = ValuePath()
        while true {
            skipSpaces()
            guard let c = peek else { break }
            switch c {
            case "#", "\n", "\r":
                break
            case "[":
                (table, tablePath) = try header(root)
            default:
                try keyValue(into: table, at: tablePath)
            }
            try endLine()
        }
        return root.freeze()
    }

    // MARK: Lines and positions

    private var position: SourcePosition {
        SourcePosition(line: line, column: i - lineStart + 1, file: file)
    }

    private var peek: Unicode.Scalar? {
        i < text.count ? text[i] : nil
    }

    private func peek(_ offset: Int) -> Unicode.Scalar? {
        i + offset < text.count ? text[i + offset] : nil
    }

    private func error(_ message: String, at position: SourcePosition? = nil) -> Diagnostic {
        Diagnostic(.error, at: position ?? self.position, path: path.description, message)
    }

    private mutating func consume(_ c: Unicode.Scalar) -> Bool {
        guard peek == c else { return false }
        i += 1
        return true
    }

    private func looksAt(_ word: String) -> Bool {
        word.unicodeScalars.enumerated().allSatisfy { peek($0.offset) == $0.element }
    }

    private mutating func skipSpaces() {
        while peek == " " || peek == "\t" { i += 1 }
    }

    private mutating func lineBreak() throws(Diagnostic) -> Bool {
        if peek == "\r" {
            guard peek(1) == "\n" else { throw error("a carriage return must be followed by a line feed") }
            i += 1
        }
        guard consume("\n") else { return false }
        line += 1
        lineStart = i
        return true
    }

    private mutating func endLine() throws(Diagnostic) {
        skipSpaces()
        try comment()
        guard let c = peek, try !lineBreak() else { return }
        throw error("expected the end of the line, found \(describe(c))")
    }

    private mutating func skipBlank() throws(Diagnostic) {
        repeat {
            skipSpaces()
            try comment()
        } while try lineBreak()
    }

    private mutating func comment() throws(Diagnostic) {
        guard consume("#") else { return }
        while let c = peek, c != "\n", c != "\r" {
            if isControl(c) { throw error("\(describe(c)) is not allowed in a comment") }
            i += 1
        }
    }

    // MARK: Keys and tables

    private mutating func key() throws(Diagnostic) -> [(name: String, position: SourcePosition)] {
        var parts: [(String, SourcePosition)] = []
        repeat {
            skipSpaces()
            let start = position
            switch peek {
            case "\"", "'":
                if peek(1) == peek, peek(2) == peek { throw error("a key cannot be a multi-line string") }
                parts.append((peek == "\"" ? try basicString() : try literalString(), start))
            case let c? where isBareKeyScalar(c):
                var name = String.UnicodeScalarView()
                while let c = peek, isBareKeyScalar(c) {
                    name.append(c)
                    i += 1
                }
                parts.append((String(name), start))
            case let c?:
                throw error("expected a key, found \(describe(c))")
            case nil:
                throw error("expected a key, found the end of the file")
            }
            skipSpaces()
        } while consume(".")
        return parts
    }

    /// Returns the table that the key-value pairs after the header go into, and its path.
    private mutating func header(_ root: TableBuilder) throws(Diagnostic) -> (TableBuilder, ValuePath) {
        i += 1
        let isArray = consume("[")
        path = ValuePath()
        let parts = try key()
        path = parts.reduce(ValuePath()) { $0.key($1.name) }
        let close = isArray ? "]]" : "]"
        guard consume("]"), !isArray || consume("]") else { throw error("expected '\(close)' to close the table header") }

        var table = root
        var tablePath = ValuePath()
        for (name, at) in parts.dropLast() {
            tablePath = tablePath.key(name)
            path = tablePath
            switch table[name]?.slot {
            case nil:
                let next = TableBuilder(.implicit, at: at)
                table.add(name, at: at, .table(next))
                table = next
            case .table(let next)?:
                table = next
            case .tables(let list)?:
                table = list[list.count - 1]
                tablePath = tablePath.index(list.count - 1)
            default:
                throw error("'\(tablePath)' is already defined at line \(table[name]!.keyPosition.line)", at: at)
            }
        }

        let (name, at) = parts[parts.count - 1]
        tablePath = tablePath.key(name)
        path = tablePath
        let existing = table[name]
        switch (existing?.slot, isArray) {
        case (nil, false):
            let next = TableBuilder(.header, at: at)
            table.add(name, at: at, .table(next))
            return (next, tablePath)
        case (nil, true):
            let next = TableBuilder(.header, at: at)
            table.add(name, at: at, .tables([next]))
            return (next, tablePath.index(0))
        case (.table(let next)?, false) where next.origin == .implicit:
            next.origin = .header
            next.position = at
            return (next, tablePath)
        case (.tables(let list)?, true):
            let next = TableBuilder(.header, at: at)
            table.replace(name, with: .tables(list + [next]))
            return (next, tablePath.index(list.count))
        default:
            throw error("'\(tablePath)' is already defined at line \(existing!.keyPosition.line)", at: at)
        }
    }

    private mutating func keyValue(into table: TableBuilder, at tablePath: ValuePath) throws(Diagnostic) {
        path = tablePath
        let parts = try key()
        path = parts.reduce(tablePath) { $0.key($1.name) }
        guard consume("=") else { throw error("expected '=' after the key") }
        skipSpaces()
        let value = try value()
        try insert(parts, value, into: table, at: tablePath)
    }

    private mutating func insert(_ parts: [(name: String, position: SourcePosition)], _ value: TOMLValue,
                                 into table: TableBuilder, at tablePath: ValuePath) throws(Diagnostic) {
        var table = table
        path = tablePath
        for (name, at) in parts.dropLast() {
            path = path.key(name)
            switch table[name]?.slot {
            case nil:
                let next = TableBuilder(.dotted, at: at)
                table.add(name, at: at, .table(next))
                table = next
            case .table(let next)? where next.origin == .dotted:
                table = next
            default:
                throw error("'\(path)' is already defined at line \(table[name]!.keyPosition.line)", at: at)
            }
        }
        let (name, at) = parts[parts.count - 1]
        path = path.key(name)
        if let existing = table[name] {
            throw error("duplicate key; it is first defined at line \(existing.keyPosition.line)", at: at)
        }
        table.add(name, at: at, .value(value))
    }

    // MARK: Values

    private mutating func value() throws(Diagnostic) -> TOMLValue {
        let start = position
        let kind: TOMLValue.Kind
        switch peek {
        case "\"", "'":
            if peek(1) == peek, peek(2) == peek { throw error("multi-line strings are not supported") }
            kind = .string(peek == "\"" ? try basicString() : try literalString())
        case "[":
            kind = try array()
        case "{":
            kind = try inlineTable()
        case "t" where looksAt("true"):
            i += 4
            kind = .boolean(true)
        case "f" where looksAt("false"):
            i += 5
            kind = .boolean(false)
        case let c? where isBareKeyScalar(c) || c == "+":
            kind = try number()
        case let c?:
            throw error("expected a value, found \(describe(c))")
        case nil:
            throw error("expected a value, found the end of the file")
        }
        return TOMLValue(kind: kind, position: start)
    }

    private mutating func number() throws(Diagnostic) -> TOMLValue.Kind {
        let start = position
        var token = ""
        while let c = peek, isBareKeyScalar(c) || c == "+" || c == "." || c == ":" {
            token.unicodeScalars.append(c)
            i += 1
        }
        let digits = token.first == "+" || token.first == "-" ? token.dropFirst() : token[...]
        if digits == "inf" || digits == "nan" {
            throw error("infinity and nan are not supported", at: start)
        }
        if let first = digits.unicodeScalars.first, !isDigit(first) {
            throw error("expected a value; put strings in quotes", at: start)
        }
        if digits.hasPrefix("0x") || digits.hasPrefix("0o") || digits.hasPrefix("0b") {
            throw error("hexadecimal, octal and binary integers are not supported", at: start)
        }
        // A date starts with a four digit year and a dash, and a time has colons. A dash
        // anywhere else belongs to a float's exponent, as in 1e-3.
        let year = digits.prefix(5).unicodeScalars
        if digits.contains(":") || (year.count == 5 && year.dropLast().allSatisfy(isDigit) && year.last == "-") {
            throw error("dates and times are not supported", at: start)
        }
        if digits.contains(".") || digits.contains("e") || digits.contains("E") {
            let parts = digits.split(separator: "e", maxSplits: 1, omittingEmptySubsequences: false)
                .flatMap { $0.split(separator: "E", maxSplits: 1, omittingEmptySubsequences: false) }
            let mantissa = parts[0].split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
            let exponent = parts.count > 1 ? parts[1] : nil
            let unsignedExponent = exponent.map { $0.first == "+" || $0.first == "-" ? $0.dropFirst() : $0[...] }
            let isFloat = parts.count <= 2 && isDecimalInteger(mantissa[0])
                && (mantissa.count == 1 || isDigits(mantissa[1]))
                && (unsignedExponent.map(isDigits) ?? true)
                && (mantissa.count == 2 || exponent != nil)
            guard isFloat else { throw error("'\(token)' is not a valid number", at: start) }
            guard let value = Double(token.replacing("_", with: "")), value.isFinite else {
                throw error("\(token) is out of range for a 64-bit float", at: start)
            }
            return .float(value)
        }
        guard isDecimalInteger(digits) else { throw error("'\(token)' is not a valid integer", at: start) }
        guard let value = Int(token.replacing("_", with: "")) else {
            throw error("\(token) is out of range for a 64-bit integer", at: start)
        }
        return .integer(value)
    }

    private mutating func basicString() throws(Diagnostic) -> String {
        let start = position
        i += 1
        var out = String.UnicodeScalarView()
        while true {
            guard let c = peek, c != "\n", c != "\r" else { throw error("the string is not closed on this line", at: start) }
            switch c {
            case "\"":
                i += 1
                return String(out)
            case "\\":
                out.append(try escape(inStringAt: start))
            default:
                if isControl(c) { throw error("\(describe(c)) must be escaped in a string") }
                out.append(c)
                i += 1
            }
        }
    }

    private mutating func escape(inStringAt start: SourcePosition) throws(Diagnostic) -> Unicode.Scalar {
        let escapeStart = position
        i += 1
        guard let c = peek, c != "\n", c != "\r" else { throw error("the string is not closed on this line", at: start) }
        i += 1
        switch c {
        case "b": return "\u{08}"
        case "t": return "\t"
        case "n": return "\n"
        case "f": return "\u{0C}"
        case "r": return "\r"
        case "e": return "\u{1B}"
        case "\"": return "\""
        case "\\": return "\\"
        case "x", "u", "U":
            let count = c == "x" ? 2 : c == "u" ? 4 : 8
            var value: UInt32 = 0
            for _ in 0..<count {
                guard let digit = peek.flatMap({ UInt32(String($0), radix: 16) }) else {
                    throw error("'\\\(c)' needs \(count) hexadecimal digits", at: escapeStart)
                }
                value = value * 16 + digit
                i += 1
            }
            guard let scalar = Unicode.Scalar(value) else {
                throw error("'\\\(c)' names \(unicodeName(value)), which is not a Unicode scalar value", at: escapeStart)
            }
            return scalar
        default:
            throw error("'\\\(c)' is not a valid escape", at: escapeStart)
        }
    }

    private mutating func literalString() throws(Diagnostic) -> String {
        let start = position
        i += 1
        var out = String.UnicodeScalarView()
        while true {
            guard let c = peek, c != "\n", c != "\r" else { throw error("the string is not closed on this line", at: start) }
            if c == "'" {
                i += 1
                return String(out)
            }
            if isControl(c) { throw error("\(describe(c)) is not allowed in a literal string") }
            out.append(c)
            i += 1
        }
    }

    private mutating func array() throws(Diagnostic) -> TOMLValue.Kind {
        let arrayPath = path
        i += 1
        var items: [TOMLValue] = []
        while true {
            try skipBlank()
            if consume("]") { break }
            path = arrayPath.index(items.count)
            items.append(try value())
            try skipBlank()
            if consume(",") { continue }
            if consume("]") { break }
            throw error(peek.map { "expected ',' or ']', found \(describe($0))" } ?? "the array is not closed")
        }
        path = arrayPath
        return .array(items)
    }

    /// TOML 1.1 allows line breaks, comments and a trailing comma in an inline table.
    private mutating func inlineTable() throws(Diagnostic) -> TOMLValue.Kind {
        let tablePath = path
        let table = TableBuilder(.inline, at: position)
        i += 1
        while true {
            try skipBlank()
            if consume("}") { break }
            path = tablePath
            let parts = try key()
            path = parts.reduce(tablePath) { $0.key($1.name) }
            guard consume("=") else { throw error("expected '=' after the key") }
            skipSpaces()
            let item = try value()
            try insert(parts, item, into: table, at: tablePath)
            try skipBlank()
            if consume(",") { continue }
            if consume("}") { break }
            throw error(peek.map { "expected ',' or '}', found \(describe($0))" } ?? "the inline table is not closed")
        }
        path = tablePath
        return .table(table.freeze())
    }
}

private func isDigit(_ c: Unicode.Scalar) -> Bool {
    ("0"..."9").contains(c)
}

/// Digits with single underscores between them.
private func isDigits(_ text: Substring) -> Bool {
    !text.isEmpty && text.unicodeScalars.allSatisfy { isDigit($0) || $0 == "_" }
        && text.first != "_" && text.last != "_" && !text.contains("__")
}

/// A decimal integer without its sign: digits with no leading zero.
private func isDecimalInteger(_ text: Substring) -> Bool {
    isDigits(text) && (text.first != "0" || text.count == 1)
}

/// Control characters TOML allows only escaped. Tab is allowed as is.
private func isControl(_ c: Unicode.Scalar) -> Bool {
    (c.value < 0x20 && c != "\t") || c.value == 0x7F
}

private func describe(_ c: Unicode.Scalar) -> String {
    c.value < 0x20 || c.value == 0x7F ? "control character \(unicodeName(c.value))" : "'\(c)'"
}

private func unicodeName(_ value: UInt32) -> String {
    let hex = String(value, radix: 16, uppercase: true)
    return "U+" + String(repeating: "0", count: max(0, 4 - hex.count)) + hex
}
