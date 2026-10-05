import Darwin
import Foundation
import Synchronization
import Testing
@testable import KosmosIPC

/// Collects lines written from other threads.
final class Lines: Sendable {
    private let lines = Mutex<[String]>([])

    func append(_ line: String) {
        lines.withLock { $0.append(line) }
    }

    var all: [String] {
        lines.withLock { $0 }
    }
}

@MainActor func testCommands(_ args: [String]) async -> Response {
    switch args {
    case ["ping"]: Response(stdout: "pong")
    case ["fail"]: Response(exitCode: 3, stdout: "partial", stderr: "failed")
    default: Response(stdout: args.joined(separator: " "))
    }
}

func makeTemporaryDirectory() -> String {
    var template = Array((NSTemporaryDirectory() + "kosmos-ipc.XXXXXX").utf8CString)
    return String(cString: mkdtemp(&template)!)
}

/// A server in its own temporary directory. Call `stop()` at the end of the test.
struct TestServer {
    let server: IPCServer
    let directory: String
    let socketPath: String
    let log = Lines()

    init(
        allowedUID: uid_t = getuid(),
        handler: @escaping @MainActor ([String]) async -> Response = testCommands
    ) throws {
        try self.init(allowedUID: allowedUID, replying: { Reply(await handler($0)) })
    }

    init(allowedUID: uid_t = getuid(), replying handler: @escaping @MainActor ([String]) async -> Reply) throws {
        directory = makeTemporaryDirectory()
        socketPath = directory + "/ipc.sock"
        let log = log
        server = try IPCServer(socketPath: socketPath, allowedUID: allowedUID, log: { log.append($0) }, handler: handler)
    }

    func stop() {
        server.stop()
        try? FileManager.default.removeItem(atPath: directory)
    }
}

struct TimedOut: Error {}

func waitUntil(_ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !(await condition()) {
        guard ContinuousClock.now < deadline else { throw TimedOut() }
        try await Task.sleep(for: .milliseconds(5))
    }
}

/// Answers `peek 5` with a held response whose hold records how it ended in `ends`, and any
/// other request as `testCommands` does.
func peekServer(ends: Lines, note: String = "") throws -> TestServer {
    try TestServer(replying: { args in
        guard args == ["peek", "5"] else { return Reply(await testCommands(args)) }
        return Reply(Response(stdout: "ignored")) { args in
            ends.append(args?.joined(separator: " ") ?? "closed")
            return Response(stderr: note)
        }
    })
}
