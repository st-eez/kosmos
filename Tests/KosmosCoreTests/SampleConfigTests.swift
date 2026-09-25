import Foundation
import Testing
@testable import KosmosCore

/// docs/sample-config.toml is Steve's AeroSpace setup translated to Kosmos.
@Suite struct SampleConfigTests {
    private static let text: String = {
        let repository = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try! String(contentsOf: repository.appending(path: "docs/sample-config.toml"), encoding: .utf8)
    }()

    private let builtIn = Display(id: 3, name: "Color LCD", isBuiltIn: true, frame: CGRect(x: 200, y: 1080, width: 1512, height: 982))
    private let asusMain = Display(id: 2, name: "VG279QE5A (1)", serial: "T9LMTF156633", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
    private let asusLeft = Display(id: 1, name: "VG279QE5A (2)", serial: "T9LMTF156643", frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080))

    private func config() throws -> Config {
        let result = Config.load(Self.text)
        #expect(result.diagnostics.map(\.description) == [])
        return try #require(result.config)
    }

    @Test func loadsWithoutDiagnostics() throws {
        let config = try config()
        // AeroSpace's 64 bindings, less ctrl-alt-a.
        #expect(config.modes.keys.sorted() == ["main"])
        #expect(config.modes["main"]?.count == 63)
        #expect(config.rules.count == 18)
        #expect(config.profiles.map(\.name) == ["home", "single", "office", "office-va24e", "laptop"])
        #expect(config.gaps.inner == 10)
    }

    /// What `kosmos list-bindings` says about each command the sample binds (DESIGN.md,
    /// section 5.12).
    @Test func describesEveryCommand() throws {
        let directions = ["left", "right", "up", "down"]
        let beside = ["left": "to the left", "right": "to the right", "up": "above", "down": "below"]
        let digits = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]
        let expected = directions.map { "focus --boundaries all-monitors-outer-frame \($0): Focus \($0), across monitors [Focus]" }
            + directions.map {
                "move --boundaries all-monitors-outer-frame --boundaries-action wrap-around-all-monitors \($0): "
                    + "Move window \($0), across monitors, wrapping around [Move]"
            }
            + digits.map { "workspace \($0): Switch to workspace \($0) [Workspace]" }
            + digits.map { "move-node-to-workspace --focus-follows-window \($0): Move window to workspace \($0) and follow [Workspace]" }
            + [
                "workspace next: Switch to the next workspace on the focused monitor [Workspace]",
                "workspace prev: Switch to the previous workspace on the focused monitor [Workspace]",
                "workspace-back-and-forth: Switch back and forth between the last two workspaces [Workspace]",
                "layout floating tiling: Toggle floating and tiling [Layout]",
                "fullscreen: Toggle fullscreen [Layout]",
                "resize smart +100: Grow window by 100 points [Resize]",
                "resize smart -100: Shrink window by 100 points [Resize]",
                "resize smart +50: Grow window by 50 points [Resize]",
                "resize smart -50: Shrink window by 50 points [Resize]",
            ]
            + directions.map { "join-with \($0): Join window with the window \(beside[$0]!) [Layout]" }
            + [
                "layout tiles horizontal vertical: Toggle the layout between horizontal and vertical [Layout]",
                "flatten-workspace-tree: Flatten the workspace tree [Layout]",
                "reload-config: Reload the config [Other]",
                "move-node-to-workspace --focus-follows-window prev: "
                    + "Move window to the previous workspace on the focused monitor and follow [Workspace]",
                "move-node-to-workspace --focus-follows-window next: "
                    + "Move window to the next workspace on the focused monitor and follow [Workspace]",
                "move-node-to-monitor --wrap-around --focus-follows-window up: "
                    + "Move window to the monitor above and follow, wrapping around [Monitor]",
                "move-node-to-monitor --wrap-around --focus-follows-window down: "
                    + "Move window to the monitor below and follow, wrapping around [Monitor]",
                "move-node-to-monitor --focus-follows-window 1: Move window to monitor 1 and follow [Monitor]",
                "move-node-to-monitor --focus-follows-window 2: Move window to monitor 2 and follow [Monitor]",
                "move-node-to-monitor --focus-follows-window 3: Move window to monitor 3 and follow [Monitor]",
                "profile home: Switch to profile home [Profile]",
                "profile office: Switch to profile office [Profile]",
                "profile laptop: Switch to profile laptop [Profile]",
                "profile single: Switch to profile single [Profile]",
            ]
        var described: [String] = []
        for binding in try #require(try config().modes["main"]) {
            let line = "\(binding.arguments.joined(separator: " ")): \(binding.command.summary) [\(binding.command.category.rawValue)]"
            if !described.contains(line) { described.append(line) }
        }
        #expect(described == expected)
    }

    @Test func home() throws {
        let setup = try config().setup(for: [builtIn, asusMain, asusLeft])
        #expect(setup.profile == "home")
        #expect(setup.workspaces.count == 10)
        #expect(setup.workspaceDisplays == ["1": 2, "2": 2, "3": 2, "4": 2, "5": 1, "6": 1, "7": 1, "8": 3, "9": 3, "0": 3])
    }

    @Test func homeWithTheLidClosed() throws {
        let setup = try config().setup(for: [asusLeft, asusMain])
        #expect(setup.profile == "home")
        #expect(setup.workspaceDisplays["8"] == 2)
    }

    @Test func single() throws {
        let asus = Display(id: 2, name: "VG279QE5A", serial: "T9LMTF156633", frame: asusMain.frame)
        let setup = try config().setup(for: [builtIn, asus])
        #expect(setup.profile == "single")
        #expect(setup.workspaceDisplays == ["1": 2, "2": 2, "3": 2, "4": 2, "5": 2, "6": 2, "7": 2, "8": 3, "9": 3, "0": 3])
    }

    @Test func office() throws {
        let ultrawide = Display(id: 4, name: "LG ULTRAWIDE", frame: CGRect(x: 0, y: 0, width: 3440, height: 1440))
        let asus = Display(id: 5, name: "ASUS VA24E", frame: CGRect(x: 3440, y: 0, width: 1920, height: 1080))
        let setup = try config().setup(for: [builtIn, ultrawide, asus])
        #expect(setup.profile == "office")
        #expect(setup.workspaceDisplays == ["1": 4, "2": 4, "3": 4, "4": 4, "5": 5, "6": 5, "7": 5, "8": 3, "9": 3, "0": 3])
    }

    @Test func officeWithTheASUSAlone() throws {
        let asus = Display(id: 5, name: "ASUS VA24E", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let setup = try config().setup(for: [builtIn, asus])
        #expect(setup.profile == "office-va24e")
        // 1 to 4 wait for the ultrawide, so they are free and show on the focused display.
        #expect(setup.workspaceDisplays == ["5": 5, "6": 5, "7": 5, "8": 3, "9": 3, "0": 3])
    }

    /// Steve's rule: an unrecognized display keeps the profile, as apply-profile.sh did.
    @Test func eachDisplaySetGivesSteveTheProfileAeroSpaceGaveHim() throws {
        let config = try config()
        let projector = Display(id: 9, name: "Projector", frame: CGRect(x: 1920, y: 0, width: 1920, height: 1080))
        let va24e = Display(id: 5, name: "ASUS VA24E", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        // The laptop alone.
        #expect(config.setup(for: [builtIn], keeping: "home").profile == "laptop")
        // The laptop and a display no profile knows keep the profile that applies.
        #expect(config.setup(for: [builtIn, projector], keeping: "home").profile == "home")
        #expect(config.setup(for: [builtIn, projector], keeping: "laptop").profile == "laptop")
        #expect(config.setup(for: [projector], keeping: "office").profile == "office")
        // At launch nothing applies yet, and the profile without `when` does.
        #expect(config.setup(for: [builtIn, projector]).profile == "laptop")
        // The twins, with or without a display no profile knows.
        #expect(config.setup(for: [builtIn, asusMain, asusLeft], keeping: "laptop").profile == "home")
        #expect(config.setup(for: [builtIn, asusMain, asusLeft, projector], keeping: "laptop").profile == "home")
        // The office's ASUS alone, and one twin unplugged.
        #expect(config.setup(for: [builtIn, va24e], keeping: "home").profile == "office-va24e")
        #expect(config.setup(for: [builtIn, asusMain], keeping: "home").profile == "single")
        #expect(config.setup(for: [builtIn, asusLeft], keeping: "home").profile == "single")
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
