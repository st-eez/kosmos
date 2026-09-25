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

    static func start(_ args: [String], socketPath: String, stdout: FileHandle, stderr: FileHandle) throws -> Process {
        let process = Process()
        process.executableURL = executable
        process.arguments = args
        process.environment = ["KOSMOS_SOCKET": socketPath]
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        return process
    }

    static func run(_ args: [String], socketPath: String) throws -> Output {
        let stdout = Pipe()
        let stderr = Pipe()
        let process = try start(args, socketPath: socketPath, stdout: stdout.fileHandleForWriting,
                                stderr: stderr.fileHandleForWriting)
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
        for args in [["ping"], ["list-bindings", "--json"]] {
            #expect(try Self.run(args, socketPath: path) == Output(
                status: 1, stdout: "", stderr: "kosmos: Kosmos is not running (nothing is listening at \(path))\n"
            ))
        }
    }

    @Test func listBindingsPrintsTheBindingsKosmosSends() async throws {
        let bindings = [
            ListedBinding(mode: "main", key: "alt-shift-left", command: "move left", description: "Move window left", category: "Move"),
            ListedBinding(mode: "main", key: "alt-1", command: "workspace 1", description: "Switch to workspace 1", category: "Workspace"),
            ListedBinding(mode: "resize", key: "esc", command: "mode main", description: "Switch to mode main", category: "Other"),
        ]
        let test = try TestServer { args in
            args.first == "list-bindings" ? listBindings(args, bindings) : await testCommands(args)
        }
        defer { test.stop() }

        let json = try Self.run(["list-bindings", "--json"], socketPath: test.socketPath)
        #expect(json.status == 0 && json.stderr == "")
        let objects = try JSONSerialization.jsonObject(with: Data(json.stdout.utf8)) as? [[String: String]]
        #expect(objects == [
            ["mode": "main", "key": "alt-shift-left", "command": "move left", "description": "Move window left", "category": "Move"],
            ["mode": "main", "key": "alt-1", "command": "workspace 1", "description": "Switch to workspace 1", "category": "Workspace"],
            ["mode": "resize", "key": "esc", "command": "mode main", "description": "Switch to mode main", "category": "Other"],
        ])

        #expect(try Self.run(["list-bindings"], socketPath: test.socketPath) == Output(status: 0, stdout: """
            mode main
              alt-shift-left  Move window left
              alt-1           Switch to workspace 1

            mode resize
              esc             Switch to mode main

            """, stderr: ""))
        #expect(try Self.run(["list-bindings", "--yaml"], socketPath: test.socketPath)
            == Output(status: 1, stdout: "", stderr: "kosmos: usage: list-bindings [--json]\n"))
    }

    @Test func subscribePrintsOneLinePerFrameUntilKosmosStops() async throws {
        let test = try TestServer()
        defer { test.stop() }
        let outputPath = test.directory + "/out"
        FileManager.default.createFile(atPath: outputPath, contents: nil)
        let output = try FileHandle(forWritingTo: URL(filePath: outputPath))
        let lines = { (try? String(contentsOfFile: outputPath, encoding: .utf8)) ?? "" }

        test.server.publish(Array(#"{"seq":1}"#.utf8))
        let process = try Self.start(["subscribe"], socketPath: test.socketPath, stdout: output,
                                     stderr: FileHandle.standardError)
        try await waitUntil { lines() == "{\"seq\":1}\n" }
        test.server.publish(Array(#"{"seq":2}"#.utf8))
        try await waitUntil { lines() == "{\"seq\":1}\n{\"seq\":2}\n" }
        test.server.stop()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}
