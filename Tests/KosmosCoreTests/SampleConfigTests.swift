import Foundation
import Testing
@testable import KosmosCore

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
        // AeroSpace's 64 bindings.
        #expect(config.modes.keys.sorted() == ["main"])
        #expect(config.modes["main"]?.count == 64)
        #expect(config.focusFollowsMouse.enabled)
        #expect(config.focusFollowsMouse.ignoreApps == ["Google Chrome for Testing"])
        #expect(config.rules.count == 18)
        #expect(config.profiles.map(\.name) == ["home", "single", "office", "office-va24e", "laptop"])
        #expect(config.gaps.inner == 10)
        #expect(config.animations)
        #expect(config.borders == BorderSettings(width: 2, active: BorderColor(hex: "#7aa2f7")!, inactive: .clear))
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
        // 1 to 4 belong on the ultrawide, so they are free.
        #expect(setup.workspaceDisplays == ["5": 5, "6": 5, "7": 5, "8": 3, "9": 3, "0": 3])
    }

    @Test func eachDisplaySetGivesSteveTheProfileAeroSpaceGaveHim() throws {
        let config = try config()
        let projector = Display(id: 9, name: "Projector", frame: CGRect(x: 1920, y: 0, width: 1920, height: 1080))
        let va24e = Display(id: 5, name: "ASUS VA24E", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        #expect(config.setup(for: [builtIn], keeping: "home").profile == "laptop")
        #expect(config.setup(for: [builtIn, projector], keeping: "home").profile == "home")
        #expect(config.setup(for: [builtIn, projector], keeping: "laptop").profile == "laptop")
        #expect(config.setup(for: [projector], keeping: "office").profile == "office")
        #expect(config.setup(for: [builtIn, projector]).profile == "laptop")
        #expect(config.setup(for: [builtIn, asusMain, asusLeft], keeping: "laptop").profile == "home")
        #expect(config.setup(for: [builtIn, asusMain, asusLeft, projector], keeping: "laptop").profile == "home")
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
        #expect(config.gaps(on: builtIn).outer.top == 5)
        #expect(config.gaps(on: asusMain).outer.top == 35)
    }
}
