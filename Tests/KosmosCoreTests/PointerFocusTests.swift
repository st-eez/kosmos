import CoreGraphics
import Testing
@testable import KosmosCore

/// Runs movements through one gate, each the window under the pointer and whether Control
/// is held, and returns which ones go on to the main actor.
private func admitted(_ movements: [(window: UInt32, control: Bool)], gate: inout PointerGate) -> [Bool] {
    movements.map { gate.admit($0.window, control: $0.control) }
}

private func admitted(_ movements: [(window: UInt32, control: Bool)]) -> [Bool] {
    var gate = PointerGate()
    return admitted(movements, gate: &gate)
}

@Suite struct PointerGateTests {
    @Test func onlyAMovementIntoAnotherWindowGoesOn() {
        // The first movement counts wherever it is, as after focus follows mouse turns on.
        #expect(admitted([(7, false), (7, false), (8, false), (8, false), (7, false)]) == [true, false, true, false, true])
    }

    @Test func controlPausesUntilTheNextMovementWithoutIt() {
        // Released inside window 8: the next movement enters it.
        #expect(admitted([(7, false), (8, true), (8, true), (8, false)]) == [true, false, false, true])
        // Back in the window where Control went down: nothing to enter.
        #expect(admitted([(7, false), (8, true), (7, true), (7, false)]) == [true, false, false, false])
    }

    @Test func theMovementAfterKosmosMovesThePointerEntersNothing() {
        // A command focused window 9 and moved the pointer there from window 7.
        var gate = PointerGate()
        #expect(admitted([(7, false)], gate: &gate) == [true])
        gate.warped()
        #expect(admitted([(9, false), (9, false), (7, false)], gate: &gate) == [false, false, true])
    }

    @Test func theMovementAfterTheMoveCountsWhereverThePointerLanded() {
        // The move landed over window 8, not the window Kosmos focused: focus stays.
        var gate = PointerGate()
        #expect(admitted([(7, false)], gate: &gate) == [true])
        gate.warped()
        #expect(admitted([(8, false), (8, false), (9, false)], gate: &gate) == [false, false, true])
    }

    @Test func theMovementAfterAMoveWithControlHeldEntersNothingEither() {
        var gate = PointerGate()
        #expect(admitted([(7, false)], gate: &gate) == [true])
        gate.warped()
        #expect(admitted([(9, true), (9, false), (7, false)], gate: &gate) == [false, false, true])
    }
}

private func session() -> Session {
    var s = Session(names: ["1", "2"], display: CGRect(x: 0, y: 0, width: 1000, height: 800))
    _ = s.add(1)
    _ = s.add(2)
    _ = s.float(2)
    _ = s.add(3)
    _ = s.park([3])
    _ = s.add(4, to: "2")
    s.adopt(1)
    return s
}

private func settings(enabled: Bool = true) -> FocusFollowsMouse {
    var settings = FocusFollowsMouse()
    settings.enabled = enabled
    settings.ignoreApps = ["Numi"]
    return settings
}

private func skip(_ window: WindowID, _ settings: FocusFollowsMouse = settings(), fullscreen: Bool = false,
                  key: KeyWindow? = .window(1),
                  app: (bundleID: String?, name: String?)? = ("com.mitchellh.ghostty", "Ghostty"),
                  stale: Bool = false) -> PointerSkip? {
    settings.skip(window, in: session(), fullscreen: fullscreen, key: key, app: app, stale: stale)
}

@Suite struct FocusFollowsMouseTests {
    @Test func tiledAndFloatingWindowsOfTheShownWorkspaceTakeFocus() {
        #expect(skip(2) == nil)                    // floating
        #expect(skip(1, key: .window(2)) == nil)   // tiled
    }

    @Test func otherWindowsLeaveFocusAlone() {
        #expect(skip(3) == .notTiled)    // parked minimized or hidden
        #expect(skip(4) == .notTiled)    // another workspace, which a switch may still show
        #expect(skip(99, app: nil) == .notTiled)   // a menu, the bar, or a window of Kosmos's own
    }

    @Test func theFocusedKeyWindowIsLeftAlone() {
        #expect(skip(1, key: .window(1)) == .focused)
        // Focused, but a panel or dialog is key: entering the window keys it again.
        #expect(skip(1, key: .window(50)) == nil)
        #expect(skip(1, key: KeyWindow.none) == nil)
    }

    @Test func ignoredAppsOffAndStale() {
        #expect(skip(2, app: ("com.numi.Numi", "Numi")) == .ignoredApp)
        #expect(skip(2, settings(enabled: false)) == .off)
        #expect(skip(2, stale: true) == .stale)
    }

    @Test func aNativeFullscreenWindowUnderThePointerTakesFocus() {
        // Window 3 is parked in native fullscreen; the pointer can only be over it, or over
        // its app's panels, on that display.
        #expect(skip(3, fullscreen: true) == nil)
        #expect(skip(3, fullscreen: true, key: .window(3)) == .focused)
        #expect(skip(3, fullscreen: true, app: ("com.numi.Numi", "Numi")) == .ignoredApp)
        #expect(skip(99, app: nil) == .notTiled)   // the fullscreen app's panel or menu
    }

    @Test func withSeveralDisplaysAFullscreenWindowLeavesTheOthersFree() {
        // The main display shows workspace 1 and has the focus; the left one shows 5.
        let left = Monitor(id: 1, frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080))
        let main = Monitor(id: 2, frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        var s = Session(names: ["1", "2", "5", "6"], monitors: [main, left], assigned: ["1": 2, "2": 2, "5": 1, "6": 1])
        _ = s.add(10)
        _ = s.add(11)
        _ = s.add(20, to: "2")
        _ = s.add(50, to: "5")
        _ = s.add(60, to: "6")
        #expect(s.isVisible(10) && s.isVisible(11) && s.isVisible(50))
        #expect(!s.isVisible(20) && !s.isVisible(60))   // hidden workspaces
        // Window 11 went native fullscreen on the main display and is key there. The
        // pointer on the left display still focuses window 50, and coming back to the main
        // display, where it finds only window 11, focuses that.
        _ = s.park([11])
        let settings = settings()
        #expect(settings.skip(50, in: s, fullscreen: false, key: .window(11), app: nil, stale: false) == nil)
        #expect(settings.skip(11, in: s, fullscreen: true, key: .window(11), app: nil, stale: false) == .focused)
        #expect(settings.skip(11, in: s, fullscreen: true, key: .window(50), app: nil, stale: false) == nil)
    }

    @Test func ignoresAppsByBundleIdentifierOrName() {
        var settings = FocusFollowsMouse()
        settings.ignoreApps = ["com.google.chrome.for.testing", "Numi"]
        #expect(settings.ignores(appID: "com.google.chrome.for.testing", appName: "Google Chrome for Testing"))
        #expect(settings.ignores(appID: nil, appName: "numi"))
        #expect(settings.ignores(appID: "COM.GOOGLE.CHROME.FOR.TESTING", appName: nil))
        // Names match whole, unlike window rules' app-name.
        #expect(!settings.ignores(appID: "com.numi.pro", appName: "Numi Pro"))
        #expect(!settings.ignores(appID: nil, appName: nil))
    }
}

@Test func onlyTiledAndFloatingWindowsOfTheShownWorkspaceAreVisible() {
    let s = session()
    #expect(s.isVisible(1) && s.isVisible(2))
    #expect(!s.isVisible(3))   // parked
    #expect(!s.isVisible(4))   // another workspace
    #expect(!s.isVisible(9))   // unknown
}

@Test func focusFollowsMouseIsForTheApp() {
    var s = session()
    #expect(s.perform(.focusFollowsMouse(.toggle)) == nil)
}

/// Whether mouse-follows-focus moves the pointer for a command as a binding writes it.
private func movesPointer(_ binding: String, from source: CommandSource = .hotkey) throws -> Bool {
    let command = try Command.parse(binding.split(separator: " ").map(String.init)).get()
    return FocusChange.command(command, from: source).movesPointer
}

@Suite struct MouseFollowsFocusTests {
    @Test func keyboardFocusAndMovesBringThePointerAlong() throws {
        for binding in ["focus --boundaries all-monitors-outer-frame left", "focus right", "focus-monitor next",
                        "move --boundaries all-monitors-outer-frame --boundaries-action wrap-around-all-monitors left",
                        "move up", "swap down", "move-node-to-monitor --wrap-around --focus-follows-window up",
                        "move-node-to-monitor 2",
                        // The window leaves, and the focus goes to the next window of the workspace.
                        "move-node-to-workspace 3"] {
            #expect(try movesPointer(binding), "\(binding)")
        }
    }

    @Test func workspaceSwitchesLeaveThePointer() throws {
        for binding in ["workspace 2", "workspace next", "workspace prev", "workspace-back-and-forth",
                        "move-node-to-workspace --focus-follows-window 2",
                        "move-node-to-workspace --focus-follows-window next"] {
            #expect(try !movesPointer(binding), "\(binding)")
        }
    }

    @Test func commandsThatKeepTheFocusLeaveThePointer() throws {
        for binding in ["join-with left", "layout tiles horizontal vertical", "layout floating tiling", "fullscreen",
                        "resize smart +50", "balance-sizes", "flatten-workspace-tree"] {
            #expect(try !movesPointer(binding), "\(binding)")
        }
    }

    @Test func theCLILeavesThePointer() throws {
        // SketchyBar's workspace pills, scripts and Raycast.
        #expect(try !movesPointer("workspace 2", from: .cli))
        #expect(try !movesPointer("focus left", from: .cli))
        #expect(try !movesPointer("move right", from: .cli))
    }

    @Test func commandTabBringsThePointerAndAClickDoesNot() {
        #expect(FocusChange.activation(keyboard: true).movesPointer)
        #expect(!FocusChange.activation(keyboard: false).movesPointer)
    }

    @Test func aMovesPlanGivesTheFrameThePointerGoesTo() throws {
        // The move sets no focus, and the pointer follows the window to the frame Kosmos
        // writes, before the app has applied it.
        var s = Session(names: ["1"], display: CGRect(x: 0, y: 0, width: 1000, height: 800))
        _ = s.add(1)
        _ = s.add(2)
        s.adopt(1)
        let before = s.frames(of: "1")
        let result = s.perform(.move(.right))
        let plan = try #require(result)
        #expect(s.focused == 1 && plan.focus == nil)
        #expect(plan.frames[1] == before[2])
    }
}
