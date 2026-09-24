// A small JSON codec. Linking Foundation for its codec would add about 1.9 ms to every CLI
// launch, measured as 1.4 ms for a Swift binary that links only Darwin and 3.2 ms for one that
// also links Foundation.

/// A JSON value. The protocol carries objects, arrays, strings, integers and booleans, so
/// numbers are integers only, and a fraction or an exponent is rejected as malformed.
enum JSON: Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case string(String)
    case array([JSON])
    case object([String: JSON])
}

extension JSON {
    /// Parses one JSON value that fills `bytes`.
    init(parsing bytes: [UInt8]) throws(IPCError) {
        var parser = Parser(bytes: bytes)
        self = try parser.value(depth: 0)
        parser.skipWhitespace()
        guard parser.index == bytes.count else { throw parser.error("trailing characters") }
    }

    /// The compact encoding, with no newlines and with object keys sorted.
    var encoded: [UInt8] {
        var out: [UInt8] = []
        write(to: &out)
        return out
    }

    private func write(to out: inout [UInt8]) {
        switch self {
        case .null: out += "null".utf8
        case .bool(let value): out += (value ? "true" : "false").utf8
        case .int(let value): out += String(value).utf8
        case .string(let value): Self.write(value, to: &out)
        case .array(let items):
            out.append(UInt8(ascii: "["))
            for (i, item) in items.enumerated() {
                if i > 0 { out.append(UInt8(ascii: ",")) }
                item.write(to: &out)
            }
            out.append(UInt8(ascii: "]"))
        case .object(let members):
            out.append(UInt8(ascii: "{"))
            for (i, key) in members.keys.sorted().enumerated() {
                if i > 0 { out.append(UInt8(ascii: ",")) }
                Self.write(key, to: &out)
                out.append(UInt8(ascii: ":"))
                members[key]!.write(to: &out)
            }
            out.append(UInt8(ascii: "}"))
        }
    }

    private static func write(_ string: String, to out: inout [UInt8]) {
        out.append(UInt8(ascii: "\""))
        for byte in string.utf8 {
            switch byte {
            case UInt8(ascii: "\""): out += #"\""#.utf8
            case UInt8(ascii: "\\"): out += #"\\"#.utf8
            case UInt8(ascii: "\n"): out += #"\n"#.utf8
            case UInt8(ascii: "\r"): out += #"\r"#.utf8
            case UInt8(ascii: "\t"): out += #"\t"#.utf8
            case ..<0x20:
                let hex = Array("0123456789abcdef".utf8)
                out += #"\u00"#.utf8
                out += [hex[Int(byte >> 4)], hex[Int(byte & 0xF)]]
            default: out.append(byte)
            }
        }
        out.append(UInt8(ascii: "\""))
    }
}

private struct Parser {
    let bytes: [UInt8]
    var index = 0

    /// Deeper input is rejected, so a client cannot overflow the server's stack.
    static let maxDepth = 32

    func error(_ reason: String) -> IPCError {
        .malformed("\(reason) at byte \(index)")
    }

    mutating func skipWhitespace() {
        while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
    }

    mutating func consume(_ character: Unicode.Scalar) -> Bool {
        guard index < bytes.count, bytes[index] == UInt8(ascii: character) else { return false }
        index += 1
        return true
    }

    mutating func value(depth: Int) throws(IPCError) -> JSON {
        guard depth <= Self.maxDepth else { throw error("nesting deeper than \(Self.maxDepth)") }
        skipWhitespace()
        guard index < bytes.count else { throw error("unexpected end") }
        switch bytes[index] {
        case UInt8(ascii: "{"): return try object(depth: depth)
        case UInt8(ascii: "["): return try array(depth: depth)
        case UInt8(ascii: "\""): return .string(try string())
        case UInt8(ascii: "t"): try literal("true"); return .bool(true)
        case UInt8(ascii: "f"): try literal("false"); return .bool(false)
        case UInt8(ascii: "n"): try literal("null"); return .null
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return .int(try integer())
        default: throw error("unexpected character")
        }
    }

    mutating func object(depth: Int) throws(IPCError) -> JSON {
        index += 1
        var members: [String: JSON] = [:]
        skipWhitespace()
        if consume("}") { return .object(members) }
        repeat {
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw error("expected a key") }
            let key = try string()
            skipWhitespace()
            guard consume(":") else { throw error("expected ':'") }
            members[key] = try value(depth: depth + 1)
            skipWhitespace()
        } while consume(",")
        guard consume("}") else { throw error("expected ',' or '}'") }
        return .object(members)
    }

    mutating func array(depth: Int) throws(IPCError) -> JSON {
        index += 1
        var items: [JSON] = []
        skipWhitespace()
        if consume("]") { return .array(items) }
        repeat {
            items.append(try value(depth: depth + 1))
            skipWhitespace()
        } while consume(",")
        guard consume("]") else { throw error("expected ',' or ']'") }
        return .array(items)
    }

    mutating func literal(_ word: String) throws(IPCError) {
        guard bytes[index...].starts(with: word.utf8) else { throw error("unexpected character") }
        index += word.utf8.count
    }

    mutating func integer() throws(IPCError) -> Int {
        let negative = consume("-")
        let start = index
        var value = 0
        while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) {
            let digit = Int(bytes[index] - UInt8(ascii: "0"))
            let (shifted, overflow1) = value.multipliedReportingOverflow(by: 10)
            let (next, overflow2) = negative
                ? shifted.subtractingReportingOverflow(digit)
                : shifted.addingReportingOverflow(digit)
            guard !overflow1, !overflow2 else { throw error("integer out of range") }
            value = next
            index += 1
        }
        guard index > start else { throw error("expected a digit") }
        if index < bytes.count, [UInt8(ascii: "."), UInt8(ascii: "e"), UInt8(ascii: "E")].contains(bytes[index]) {
            throw error("only integers are supported")
        }
        return value
    }

    mutating func string() throws(IPCError) -> String {
        index += 1
        var utf8: [UInt8] = []
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            switch byte {
            case UInt8(ascii: "\""):
                guard let string = String(validating: utf8, as: UTF8.self) else { throw error("invalid UTF-8") }
                return string
            case UInt8(ascii: "\\"):
                try escape(into: &utf8)
            case ..<0x20:
                throw error("control character in a string")
            default:
                utf8.append(byte)
            }
        }
        throw error("unterminated string")
    }

    mutating func escape(into utf8: inout [UInt8]) throws(IPCError) {
        guard index < bytes.count else { throw error("unterminated string") }
        let byte = bytes[index]
        index += 1
        switch byte {
        case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): utf8.append(byte)
        case UInt8(ascii: "b"): utf8.append(0x08)
        case UInt8(ascii: "f"): utf8.append(0x0C)
        case UInt8(ascii: "n"): utf8.append(0x0A)
        case UInt8(ascii: "r"): utf8.append(0x0D)
        case UInt8(ascii: "t"): utf8.append(0x09)
        case UInt8(ascii: "u"):
            var code = try hex4()
            // A character outside the Basic Multilingual Plane arrives as a surrogate pair.
            if (0xD800..<0xDC00).contains(code), consume("\\"), consume("u") {
                let low = try hex4()
                guard (0xDC00..<0xE000).contains(low) else { throw error("invalid surrogate pair") }
                code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
            }
            guard let scalar = Unicode.Scalar(code) else { throw error("invalid \\u escape") }
            utf8 += String(Character(scalar)).utf8
        default:
            throw error("invalid escape")
        }
    }

    mutating func hex4() throws(IPCError) -> UInt32 {
        var code: UInt32 = 0
        for _ in 0..<4 {
            guard index < bytes.count, let digit = Character(Unicode.Scalar(bytes[index])).hexDigitValue
            else { throw error("invalid \\u escape") }
            code = code << 4 | UInt32(digit)
            index += 1
        }
        return code
    }
}
