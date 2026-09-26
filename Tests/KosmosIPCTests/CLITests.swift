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

    @Test func saysWhenKosmosIsNotRunning() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let path = directory + "/ipc.sock"
        #expect(try Self.run(["ping"], socketPath: path) == Output(
            status: 1, stdout: "", stderr: "kosmos: Kosmos is not running (nothing is listening at \(path))\n"
        ))
    }
}
