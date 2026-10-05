import Foundation
import Testing
@testable import KosmosIPC

/// Runs the built `kosmos` executable against test servers through `KOSMOS_SOCKET`.
@Suite struct CLITests {
    /// The executable sits beside the test bundle in the build products.
    static let executable = Bundle(for: Marker.self).bundleURL.deletingLastPathComponent().appending(path: "kosmos")
    private final class Marker {}

    struct Output: Equatable {
        var status: Int32
        var stdout: String
        var stderr: String
    }

    static func run(_ args: [String], socketPath: String) throws -> Output {
        let stdout = Pipe()
        let stderr = Pipe()
        let process = Process()
        process.executableURL = executable
        process.arguments = args
        process.environment = ["KOSMOS_SOCKET": socketPath]
        process.standardOutput = stdout.fileHandleForWriting
        process.standardError = stderr.fileHandleForWriting
        try process.run()
        try stdout.fileHandleForWriting.close()
        try stderr.fileHandleForWriting.close()
        let out = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let err = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return Output(status: process.terminationStatus, stdout: out, stderr: err)
    }

    @Test func printsTheResponseAndExitsWithItsCode() async throws {
        let test = try TestServer()
        defer { test.stop() }
        #expect(try Self.run(["ping"], socketPath: test.socketPath) == Output(status: 0, stdout: "pong\n", stderr: ""))
        #expect(try Self.run(["fail"], socketPath: test.socketPath)
            == Output(status: 3, stdout: "partial\n", stderr: "failed\n"))
        #expect(try Self.run([], socketPath: test.socketPath)
            == Output(status: 2, stdout: "", stderr: "usage: kosmos <command> [args...]\n"))
    }

    @Test func peekRunsTheCommandUnderAHeldResponseAndReportsItsStatus() throws {
        let ends = Lines()
        let test = try peekServer(ends: ends, note: "kosmos: the peek ended before the command did: the displays changed")
        defer { test.stop() }
        #expect(try Self.run(["peek", "5", "--", "/bin/sh", "-c", "echo out; echo err >&2; exit 3"], socketPath: test.socketPath)
            == Output(status: 3, stdout: "out\n", stderr: "err\nkosmos: the peek ended before the command did: the displays changed\n"))
        #expect(ends.all == ["ended 3"])
        // Killed by a signal, as a shell reports it.
        #expect(try Self.run(["peek", "5", "--", "/bin/sh", "-c", "kill -TERM $$"], socketPath: test.socketPath).status == 143)
        #expect(ends.all == ["ended 3", "ended 143"])
    }

    @Test func peekRunsTheCommandAsIsWhenNothingIsHeld() throws {
        let ends = Lines()
        let test = try peekServer(ends: ends)
        defer { test.stop() }
        #expect(try Self.run(["peek", "6", "--", "echo", "hi"], socketPath: test.socketPath) == Output(status: 0, stdout: "hi\n", stderr: ""))
        let missing = test.directory + "/missing"
        #expect(try Self.run(["peek", "5", "--", missing], socketPath: test.socketPath)
            == Output(status: 127, stdout: "", stderr: "kosmos: \(missing): No such file or directory\n"))
        #expect(ends.all == ["ended 127"])
        // A Kosmos that is not running conceals nothing.
        #expect(try Self.run(["peek", "5", "--", "echo", "hi"], socketPath: test.directory + "/none.sock")
            == Output(status: 0, stdout: "hi\n", stderr: ""))
    }

    @Test func peekNeedsAWindowIdAndACommand() throws {
        let usage = Output(status: 2, stdout: "", stderr: "usage: kosmos peek <window id> -- <command> [args...]\n")
        for args in [["peek"], ["peek", "x", "--", "true"], ["peek", "5", "true"], ["peek", "5", "--"]] {
            #expect(try Self.run(args, socketPath: "unused.sock") == usage)
        }
    }

    @Test func saysWhenKosmosIsNotRunning() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let path = directory + "/ipc.sock"
        #expect(try Self.run(["ping"], socketPath: path) == Output(
            status: 1, stdout: "", stderr: "kosmos: Kosmos is not running (nothing is listening at \(path))\n"
        ))
    }
}
