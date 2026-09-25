import Darwin

// The wire format is in docs/ipc.md.

let protocolVersion = 1

/// Far above any message, so a garbage length cannot make a reader buffer gigabytes.
let maxFrameLength = 16 << 20

/// `$HOME` first: `getpwuid` asks the directory service, which adds about 0.75 ms to a CLI
/// launch.
public func kosmosSocketPath() -> String {
    let home = getenv("HOME").map { String(cString: $0) } ?? String(cString: getpwuid(getuid()).pointee.pw_dir)
    return home + "/Library/Application Support/Kosmos/ipc.sock"
}

public struct Response: Equatable, Sendable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String

    public init(exitCode: Int32 = 0, stdout: String = "", stderr: String = "") {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public enum IPCError: Error, Equatable, CustomStringConvertible {
    case notRunning(socketPath: String)
    case timedOut
    case closed
    case malformed(String)
    case protocolMismatch(client: Int)
    case unsafeDirectory(String)
    case pathTooLong(String)
    case system(String, Int32)

    public var description: String {
        switch self {
        case .notRunning(let path): "Kosmos is not running (nothing is listening at \(path))"
        case .timedOut: "Kosmos did not reply in time"
        case .closed: "Kosmos closed the connection"
        case .malformed(let reason): "malformed message: \(reason)"
        case .protocolMismatch(let client):
            "this CLI speaks protocol \(client) and Kosmos \(kosmosVersion) speaks \(protocolVersion); use the CLI from the same release"
        case .unsafeDirectory(let reason): reason
        case .pathTooLong(let path): "the socket path is longer than 103 bytes: \(path)"
        case .system(let call, let code): "\(call): \(String(cString: strerror(code)))"
        }
    }
}

enum Request: Equatable {
    case command([String])
    case subscribe
}

extension Request {
    var encoded: [UInt8] {
        switch self {
        case .command(let args):
            JSON.object(["protocol": .int(protocolVersion), "args": .array(args.map(JSON.string))]).encoded
        case .subscribe:
            JSON.object(["protocol": .int(protocolVersion), "subscribe": .bool(true)]).encoded
        }
    }

    init(decoding body: [UInt8]) throws(IPCError) {
        guard case .object(let members) = try JSON(parsing: body) else {
            throw IPCError.malformed("a request must be an object")
        }
        guard case .int(let version) = members["protocol"] else {
            throw IPCError.malformed("the request has no protocol version")
        }
        guard version == protocolVersion else { throw IPCError.protocolMismatch(client: version) }
        if case .array(let items) = members["args"] {
            self = .command(try items.map { item throws(IPCError) in
                guard case .string(let arg) = item else { throw IPCError.malformed("args must be strings") }
                return arg
            })
        } else if members["subscribe"] == .bool(true) {
            self = .subscribe
        } else {
            throw IPCError.malformed("the request has neither args nor subscribe")
        }
    }
}

extension Response {
    init(_ error: any Error) {
        self.init(exitCode: 1, stderr: "kosmos: \(error)")
    }

    var encoded: [UInt8] {
        JSON.object(["exitCode": .int(Int(exitCode)), "stdout": .string(stdout), "stderr": .string(stderr)]).encoded
    }

    init(decoding body: [UInt8]) throws(IPCError) {
        guard case .object(let members) = try JSON(parsing: body),
              case .int(let exitCode) = members["exitCode"], let exitCode = Int32(exactly: exitCode),
              case .string(let stdout) = members["stdout"],
              case .string(let stderr) = members["stderr"]
        else { throw IPCError.malformed("the response lacks exitCode, stdout or stderr") }
        self.init(exitCode: exitCode, stdout: stdout, stderr: stderr)
    }
}

func frame(_ body: [UInt8]) -> [UInt8] {
    let length = UInt32(body.count)
    return [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: length >> $0) } + body
}

struct FrameDecoder {
    private var buffer: [UInt8] = []

    var isEmpty: Bool { buffer.isEmpty }

    mutating func append(_ bytes: some Sequence<UInt8>) {
        buffer += bytes
    }

    /// Throws as soon as a length above `maxFrameLength` arrives.
    mutating func next() throws(IPCError) -> [UInt8]? {
        guard buffer.count >= 4 else { return nil }
        let length = buffer[0..<4].reduce(0) { $0 << 8 | Int($1) }
        guard length <= maxFrameLength else {
            throw IPCError.malformed("a frame of \(length) bytes exceeds the limit of \(maxFrameLength)")
        }
        guard buffer.count >= 4 + length else { return nil }
        let body = Array(buffer[4 ..< 4 + length])
        buffer.removeFirst(4 + length)
        return body
    }
}

func withSocketAddress<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) throws(IPCError) -> T {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw IPCError.pathTooLong(path) }
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
    return withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
}
