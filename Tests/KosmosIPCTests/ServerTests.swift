import Darwin
import Foundation
import Testing
@testable import KosmosIPC

@Suite struct ServerTests {
    @Test func answersCommands() async throws {
        let test = try TestServer()
        defer { test.stop() }
        #expect(try IPCClient.send(["ping"], socketPath: test.socketPath) == Response(stdout: "pong"))
        #expect(try IPCClient.send(["fail"], socketPath: test.socketPath)
            == Response(exitCode: 3, stdout: "partial", stderr: "failed"))
        #expect(try IPCClient.send(["say", "héllo \"wörld\"", ""], socketPath: test.socketPath).stdout
            == "say héllo \"wörld\" ")
    }

    @Test func answersBadRequestsWithAnError() async throws {
        let test = try TestServer()
        defer { test.stop() }
        let cases: [([UInt8], String)] = [
            (frame(Array("{not json".utf8)), "malformed message: expected a key at byte 1"),
            ([0xFF, 0xFF, 0xFF, 0xFF], "exceeds the limit"),
            (frame(Array(#"{"protocol":9,"args":["ping"]}"#.utf8)), "this CLI speaks protocol 9"),
        ]
        for (bytes, message) in cases {
            let connection = try ClientConnection(socketPath: test.socketPath)
            try connection.write(bytes, deadline: .now + .seconds(5))
            let body = try #require(try connection.readFrame(deadline: .now + .seconds(5)))
            let response = try Response(decoding: body)
            #expect(response.exitCode == 1)
            #expect(response.stderr.hasPrefix("kosmos: "))
            #expect(response.stderr.contains(message))
        }
    }

    @Test func rejectsClientsOfAnotherUser() async throws {
        let test = try TestServer(allowedUID: getuid() + 1)
        defer { test.stop() }
        #expect(throws: IPCError.closed) { try IPCClient.send(["ping"], socketPath: test.socketPath) }
        #expect(test.log.all == ["rejected a client from pid \(getpid()) with uid \(getuid())"])
    }

    @Test func closesAClientThatSendsNoRequest() async throws {
        let test = try TestServer()
        defer { test.stop() }
        let connection = try ClientConnection(socketPath: test.socketPath)
        let start = ContinuousClock.now
        #expect(try connection.readFrame(deadline: .now + .seconds(5)) == nil)
        #expect(ContinuousClock.now - start >= .milliseconds(900))
    }

    @Test func slowCommandDoesNotHoldUpOtherClients() async throws {
        let gate = Gate()
        let handler: @MainActor ([String]) async -> Response = { args in
            if args == ["slow"] {
                await gate.wait()
                return Response(stdout: "done")
            }
            return await testCommands(args)
        }
        let test = try TestServer(handler: handler)
        defer { test.stop() }
        let path = test.socketPath
        let slow = Task.detached { try IPCClient.send(["slow"], socketPath: path) }
        try await waitUntil { await gate.isWaiting }
        #expect(try IPCClient.send(["ping"], socketPath: path).stdout == "pong")
        await gate.open()
        #expect(try await slow.value.stdout == "done")
    }

    @Test func survivesAClientThatLeavesBeforeItsResponse() async throws {
        let gate = Gate()
        let handler: @MainActor ([String]) async -> Response = { args in
            await gate.wait()
            return await testCommands(args)
        }
        let test = try TestServer(handler: handler)
        defer { test.stop() }
        var connection: ClientConnection? = try ClientConnection(socketPath: test.socketPath)
        try connection?.write(frame(Request.command(["ping"]).encoded), deadline: .now + .seconds(5))
        try await waitUntil { await gate.isWaiting }
        connection = nil
        await gate.open()
        // Writing the response to the closed socket must fail with EPIPE instead of raising
        // SIGPIPE, which would end this process.
        let path = test.socketPath
        let next = Task.detached { try IPCClient.send(["ping"], socketPath: path) }
        try await waitUntil { await gate.isWaiting }
        await gate.open()
        #expect(try await next.value.stdout == "pong")
    }

    @Test func subscriberGetsTheLatestFrameThenEachPublish() async throws {
        let test = try TestServer()
        defer { test.stop() }
        test.server.publish(Array(#"{"seq":1}"#.utf8))
        test.server.publish(Array(#"{"seq":2}"#.utf8))
        let frames = Lines()
        let path = test.socketPath
        let subscriber = Task.detached {
            try IPCClient.subscribe(socketPath: path) { frames.append(String(decoding: $0, as: UTF8.self)) }
        }
        try await waitUntil { frames.all.count == 1 }
        test.server.publish(Array(#"{"seq":3}"#.utf8))
        try await waitUntil { frames.all.count == 2 }
        test.server.stop()
        #expect(try await subscriber.value == Response())
        #expect(frames.all == [#"{"seq":2}"#, #"{"seq":3}"#])
    }

    @Test func slowSubscriberSkipsToTheNewestFrames() async throws {
        let test = try TestServer()
        defer { test.stop() }
        let connection = try ClientConnection(socketPath: test.socketPath)
        try connection.write(frame(Request.subscribe.encoded), deadline: .now + .seconds(5))
        let answer = try #require(try connection.readFrame(deadline: .now + .seconds(5)))
        #expect(try Response(decoding: answer) == Response())

        // The client stops reading. Each frame is far larger than the socket buffers, so the
        // first frame written stays in the middle of its write, and each later frame replaces
        // the one waiting. Which frame is first depends on when the server finishes writing the
        // subscribe response: frame 1 waits too if the response is still in flight.
        let count = 10
        let padding = String(repeating: "x", count: 256 << 10)
        for seq in 1...count {
            test.server.publish(Array(#"{"pad":"\#(padding)","seq":\#(seq)}"#.utf8))
        }

        var received: [Int] = []
        while received.last != count {
            let body = try #require(try connection.readFrame(deadline: .now + .seconds(5)))
            guard case .object(let members) = try JSON(parsing: body), case .int(let seq) = members["seq"] else {
                Issue.record("a frame without seq")
                return
            }
            received.append(seq)
        }
        // At most the frame that was in flight, then the newest.
        #expect(received.count <= 2)
        // The subscriber is still connected, with nothing more to read.
        #expect(throws: IPCError.timedOut) { _ = try connection.readFrame(deadline: .now + .milliseconds(200)) }
    }

    @Test func replacesAStaleSocketAndRestarts() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let path = directory + "/ipc.sock"

        // A server that died without cleaning up leaves a bound socket file with no listener.
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #expect(try withSocketAddress(path) { bind(fd, $0, $1) } == 0)
        close(fd)
        #expect(throws: IPCError.notRunning(socketPath: path)) { try IPCClient.send(["ping"], socketPath: path) }

        let first = try IPCServer(socketPath: path, log: { _ in }, handler: testCommands)
        #expect(try IPCClient.send(["ping"], socketPath: path).stdout == "pong")
        first.stop()
        #expect(access(path, F_OK) != 0)

        let second = try IPCServer(socketPath: path, log: { _ in }, handler: testCommands)
        defer { second.stop() }
        #expect(try IPCClient.send(["ping"], socketPath: path).stdout == "pong")
    }

    @Test func checksTheSocketDirectory() throws {
        #expect(throws: IPCError.unsafeDirectory("the socket path must be absolute: ipc.sock")) {
            try IPCServer(socketPath: "ipc.sock", log: { _ in }, handler: testCommands)
        }
        #expect(throws: IPCError.unsafeDirectory("/usr belongs to uid 0, not \(getuid())")) {
            try IPCServer(socketPath: "/usr/ipc.sock", log: { _ in }, handler: testCommands)
        }

        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        chmod(directory, 0o755)
        let server = try IPCServer(socketPath: directory + "/ipc.sock", log: { _ in }, handler: testCommands)
        server.stop()
        var info = stat()
        stat(directory, &info)
        #expect(info.st_mode & 0o777 == 0o700)
    }
}

/// Holds a command on the main actor until the test opens it.
@MainActor final class Gate {
    private var waiter: CheckedContinuation<Void, Never>?

    var isWaiting: Bool { waiter != nil }

    func wait() async {
        await withCheckedContinuation { waiter = $0 }
    }

    func open() {
        waiter?.resume()
        waiter = nil
    }
}
