import Darwin

// The wire format. Each message is a frame, made of a 4 byte length in network byte order and
// then that many bytes of body. A client sends one request frame. The server answers with one
// response frame and closes, or, for a subscription, sends a response frame and then one frame
// per published payload until either side closes.
//
// Request bodies:  {"args":["workspace","3"],"protocol":1}  or  {"protocol":1,"subscribe":true}
// Response bodies: {"exitCode":0,"stderr":"","stdout":"pong"}

/// The request format revision. A request with another revision gets an error response.
let protocolVersion = 1

/// The largest frame body either side accepts. It is far above any request, response or
/// snapshot, and it stops a garbage length from making a reader buffer gigabytes.
let maxFrameLength = 16 << 20

/// The path Kosmos.app serves and the CLI connects to, in the user's 0700 Kosmos directory.
/// The home directory comes from `$HOME` when it is set, because `getpwuid` asks the directory
/// service and adds about 0.75 ms to a CLI launch (measured).
public func kosmosSocketPath() -> String {
    let home = getenv("HOME").map { String(cString: $0) } ?? String(cString: getpwuid(getuid()).pointee.pw_dir)
    return home + "/Library/Application Support/Kosmos/ipc.sock"
}

/// The app's answer to a command. The CLI prints `stdout` and `stderr`, each followed by a
/// newline when it is not empty, and exits with `exitCode`.
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

/// Prefixes `body` with its length.
func frame(_ body: [UInt8]) -> [UInt8] {
    let length = UInt32(body.count)
    return [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: length >> $0) } + body
}

/// Splits a byte stream into frame bodies. Append bytes as they arrive, then call `next()`
/// until it returns nil.
struct FrameDecoder {
    private var buffer: [UInt8] = []

    /// True when no bytes of an unfinished frame are waiting.
    var isEmpty: Bool { buffer.isEmpty }

    mutating func append(_ bytes: some Sequence<UInt8>) {
        buffer += bytes
    }

    /// The next complete frame body, or nil until more bytes arrive. Throws as soon as a
    /// length above `maxFrameLength` arrives.
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

/// Calls `body` with a Unix socket address for `path`.
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
