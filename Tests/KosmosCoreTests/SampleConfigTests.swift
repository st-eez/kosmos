import Foundation
import Testing
@testable import KosmosCore

/// docs/sample-config.toml is Steve's AeroSpace setup translated to Kosmos.
@Suite struct SampleConfigTests {
    private static let text: String = {
        let repository = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try! String(contentsOf: repository.appending(path: "docs/sample-config.toml"), encoding: .utf8)
    }()

    private let builtIn = Display(name: "Color LCD", isBuiltIn: true)
    private let asusMain = Display(name: "VG279QE5A (1)", serial: "T9LMTF156633")
    private let asusLeft = Display(name: "VG279QE5A (2)", serial: "T9LMTF156643")

    private func config() throws -> Config {
        let result = Config.load(Self.text)
        #expect(result.diagnostics.map(\.description) == [])
        return try #require(result.config)
    }

    @Test func loadsWithoutDiagnostics() throws {
        let config = try config()
        // AeroSpace's 64 bindings, less the 11 that wait on multi-monitor commands.
        #expect(config.modes.keys.sorted() == ["main"])
        #expect(config.modes["main"]?.count == 53)
        #expect(config.focusFollowsMouse.enabled && config.focusFollowsMouse.pauseKey == .ctrl)
        #expect(config.focusFollowsMouse.ignoreApps == ["Google Chrome for Testing"])
        #expect(config.rules.count == 18)
        #expect(config.profiles.map(\.name) == ["home", "single", "office", "laptop"])
        #expect(config.gaps.inner == 10)
    }

    @Test func home() throws {
        let setup = try config().setup(for: [builtIn, asusMain, asusLeft])
        #expect(setup.profile == "home")
        #expect(setup.workspaces.count == 10)
        #expect(setup.workspaceDisplays == ["1": 1, "2": 1, "3": 1, "4": 1, "5": 2, "6": 2, "7": 2, "8": 0, "9": 0, "0": 0])
    }

    @Test func homeWithTheLidClosed() throws {
        let setup = try config().setup(for: [asusLeft, asusMain])
        #expect(setup.profile == "home")
        #expect(setup.workspaceDisplays["8"] == 1)
    }

    @Test func single() throws {
        let setup = try config().setup(for: [builtIn, Display(name: "VG279QE5A", serial: "T9LMTF156633")])
        #expect(setup.profile == "single")
        #expect(setup.workspaceDisplays == ["1": 1, "2": 1, "3": 1, "4": 1, "5": 1, "6": 1, "7": 1, "8": 0, "9": 0, "0": 0])
    }

    @Test func office() throws {
        let setup = try config().setup(for: [builtIn, Display(name: "LG ULTRAWIDE"), Display(name: "ASUS VA24E")])
        #expect(setup.profile == "office")
        #expect(setup.workspaceDisplays == ["1": 1, "2": 1, "3": 1, "4": 1, "5": 2, "6": 2, "7": 2, "8": 0, "9": 0, "0": 0])
    }

    @Test func laptop() throws {
        let config = try config()
        let setup = config.setup(for: [builtIn])
        #expect(setup.profile == "laptop")
        #expect(setup.workspaces == ["1", "2", "3", "4", "5"])
        #expect(setup.mergeWorkspaces == ["6": "1", "7": "2", "8": "3", "9": "4", "0": "5"])
        func workspace(_ appID: String?, _ appName: String) -> String? {
            setup.rules.first { $0.matches(appID: appID, appName: appName) }?.workspace
        }
        #expect(workspace("com.spotify.client", "Spotify") == "4")
        #expect(workspace("com.apple.Safari.WebApp.1234", "YouTube") == "4")
        #expect(workspace("com.google.Chrome", "Google Chrome") == "4")
        #expect(workspace("com.mitchellh.ghostty", "Ghostty") == "1")
        #expect(config.outerGaps(on: builtIn).top == 5)
        #expect(config.outerGaps(on: asusMain).top == 35)
    }
}
