import CoreGraphics
import Testing
@testable import KosmosCore

// Steve's desk, less the built-in display: the left panel and the main panel.
private let leftPanel = Monitor(id: 1, frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080))
private let mainPanel = Monitor(id: 2, frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))

/// A movement: the window under the pointer, the pointer's x, left of 0 on the left panel,
/// and whether Control is held.
private typealias Movement = (window: UInt32, x: CGFloat, control: Bool)

private func gate() -> PointerGate {
    var gate = PointerGate()
    gate.monitors = [leftPanel, mainPanel]
    return gate
}

/// Runs movements through the gate and returns what each one entered, or nil.
private func entered(_ movements: [Movement], gate: inout PointerGate) -> [PointerGate.Entered?] {
    movements.map { gate.admit($0.window, at: CGPoint(x: $0.x, y: 500), control: $0.control) }
}

private func entered(_ movements: [Movement]) -> [PointerGate.Entered?] {
    var gate = gate()
    return entered(movements, gate: &gate)
}

private func into(_ window: UInt32, display: DisplayID? = nil) -> PointerGate.Entered? {
    PointerGate.Entered(window: window, display: display)
}

@Suite struct PointerGateTests {
    @Test func onlyAMovementIntoAnotherWindowGoesOn() {
        // The first movement counts wherever it is, as after focus follows mouse turns on.
        #expect(entered([(7, 100, false), (7, 200, false), (8, 1000, false), (8, 1100, false), (7, 100, false)])
            == [into(7, display: 2), nil, into(8), nil, into(7)])
    }

    @Test func aMovementOntoAnotherDisplayGoesOnOverTheSameWindow() {
        // The desktop, window 5, under the pointer on both panels.
        #expect(entered([(7, 100, false), (5, -100, false), (5, -200, false), (5, 100, false)])
            == [into(7, display: 2), into(5, display: 1), nil, into(5, display: 2)])
    }

    @Test func controlPausesUntilTheNextMovementWithoutIt() {
        // Released inside window 8: the next movement enters it.
        #expect(entered([(7, 100, false), (8, 1000, true), (8, 1010, true), (8, 1020, false)])
            == [into(7, display: 2), nil, nil, into(8)])
        // Back in the window where Control went down: nothing to enter.
        #expect(entered([(7, 100, false), (8, 1000, true), (7, 100, true), (7, 110, false)])
            == [into(7, display: 2), nil, nil, nil])
        // Released on the other panel: the next movement enters it.
        #expect(entered([(7, 100, false), (5, -100, true), (5, -110, false)])
            == [into(7, display: 2), nil, into(5, display: 1)])
    }

    @Test func theMovementAfterKosmosMovesThePointerEntersNothing() {
        // A command focused window 9 and moved the pointer there from window 7.
        var gate = gate()
        #expect(entered([(7, 100, false)], gate: &gate) == [into(7, display: 2)])
        gate.warped()
        #expect(entered([(9, 1500, false), (9, 1510, false), (7, 100, false)], gate: &gate) == [nil, nil, into(7)])
    }

    @Test func theMovementAfterTheMoveCountsWhereverThePointerLanded() {
        // The move landed over window 8, not the window Kosmos focused: focus stays.
        var gate = gate()
        #expect(entered([(7, 100, false)], gate: &gate) == [into(7, display: 2)])
        gate.warped()
        #expect(entered([(8, 1500, false), (8, 1510, false), (9, 1800, false)], gate: &gate) == [nil, nil, into(9)])
    }

    @Test func theMovementAfterAMoveToAnotherDisplayEntersNothingEither() {
        var gate = gate()
        #expect(entered([(7, 100, false)], gate: &gate) == [into(7, display: 2)])
        gate.warped()
        #expect(entered([(50, -900, false), (50, -910, false), (7, 100, false)], gate: &gate)
            == [nil, nil, into(7, display: 2)])
    }

    @Test func theMovementAfterAMoveWithControlHeldEntersNothingEither() {
        var gate = gate()
        #expect(entered([(7, 100, false)], gate: &gate) == [into(7, display: 2)])
        gate.warped()
        #expect(entered([(9, 1500, true), (9, 1510, false), (7, 100, false)], gate: &gate) == [nil, nil, into(7)])
    }

    @Test func turningOnAgainCountsTheNextMovementWherever() {
        var gate = gate()
        #expect(entered([(7, 100, false)], gate: &gate) == [into(7, display: 2)])
        gate.reset()
        #expect(gate.monitors.count == 2)
        #expect(entered([(7, 110, false)], gate: &gate) == [into(7, display: 2)])
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

    @Test func onToADisplayShowingAnEmptyWorkspaceThatWorkspaceTakesFocus() {
        // Workspace 1 on the main panel has the focus and a window; the left panel shows
        // empty workspace 7.
        var s = Session(names: ["1", "6", "7"], monitors: [mainPanel, leftPanel], assigned: ["1": 2, "6": 1, "7": 1])
        _ = s.add(10)
        _ = s.add(60, to: "6")
        _ = s.perform(.workspace(.named("7")))
        _ = s.perform(.workspace(.named("1")))
        let settings = settings()
        #expect(s.workspace(shownOn: 1) == "7")
        #expect(settings.emptyWorkspace(entered: 1, in: s) == "7")
        // Back on the main panel, over a gap or the desktop: its workspace has a window.
        #expect(settings.emptyWorkspace(entered: 2, in: s) == nil)
        // Workspace 7 focused already, or focus follows mouse off.
        var focused = s
        _ = focused.perform(.workspace(.named("7")))
        #expect(settings.emptyWorkspace(entered: 1, in: focused) == nil)
        #expect(FocusFollowsMouse().emptyWorkspace(entered: 1, in: s) == nil)
        // The left panel showing workspace 6, which has a window, keeps focus where it is.
        _ = s.perform(.workspace(.named("6")))
        _ = s.perform(.workspace(.named("1")))
        #expect(settings.emptyWorkspace(entered: 1, in: s) == nil)
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
private func movesPointer(_ binding: String, from source: CommandSource = .hotkey, toAnotherDisplay: Bool = false) throws -> Bool {
    let command = try Command.parse(binding.split(separator: " ").map(String.init)).get()
    return FocusChange.command(command, from: source).movesPointer(toAnotherDisplay: toAnotherDisplay)
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
            #expect(try movesPointer(binding, toAnotherDisplay: true), "\(binding)")
        }
    }

    @Test func workspaceSwitchesMoveThePointerOnlyToAnotherDisplay() throws {
        for binding in ["workspace 2", "workspace next", "workspace prev", "workspace-back-and-forth",
                        "move-node-to-workspace --focus-follows-window 2",
                        "move-node-to-workspace --focus-follows-window next"] {
            #expect(try !movesPointer(binding), "\(binding)")
            // alt-6 for workspace 6, which the left panel shows or hides, with the pointer on
            // the main panel.
            #expect(try movesPointer(binding, toAnotherDisplay: true), "\(binding)")
        }
    }

    @Test func commandsThatKeepTheFocusLeaveThePointer() throws {
        for binding in ["join-with left", "layout tiles horizontal vertical", "layout floating tiling", "fullscreen",
                        "resize smart +50", "balance-sizes", "flatten-workspace-tree"] {
            #expect(try !movesPointer(binding), "\(binding)")
            #expect(try !movesPointer(binding, toAnotherDisplay: true), "\(binding)")
        }
    }

    @Test func theCLILeavesThePointer() throws {
        // SketchyBar's workspace pills, scripts and Raycast.
        for binding in ["workspace 2", "focus left", "move right"] {
            #expect(try !movesPointer(binding, from: .cli), "\(binding)")
            #expect(try !movesPointer(binding, from: .cli, toAnotherDisplay: true), "\(binding)")
        }
    }

    @Test func commandTabBringsThePointerAndAClickDoesNot() {
        #expect(FocusChange.activation(keyboard: true, intoHiddenWorkspace: false).movesPointer(toAnotherDisplay: false))
        #expect(!FocusChange.activation(keyboard: false, intoHiddenWorkspace: false).movesPointer(toAnotherDisplay: false))
        #expect(!FocusChange.activation(keyboard: false, intoHiddenWorkspace: false).movesPointer(toAnotherDisplay: true))
    }

    @Test func anActivationIntoAHiddenWorkspaceMovesThePointerOnlyToAnotherDisplay() {
        // A launcher's hotkey activates Spotify on workspace 6, which the left panel hides,
        // with the pointer on the main panel.
        #expect(FocusChange.activation(keyboard: true, intoHiddenWorkspace: true).movesPointer(toAnotherDisplay: true))
        #expect(!FocusChange.activation(keyboard: true, intoHiddenWorkspace: true).movesPointer(toAnotherDisplay: false))
        // A Dock click leaves the pointer wherever the window is.
        #expect(!FocusChange.activation(keyboard: false, intoHiddenWorkspace: true).movesPointer(toAnotherDisplay: true))
    }

    @Test func aWindowIsOnAnotherDisplayThanThePointerByItsWorkspace() {
        var s = Session(names: ["1", "6", "7"], monitors: [mainPanel, leftPanel], assigned: ["1": 2, "6": 1, "7": 1])
        _ = s.add(10)
        _ = s.add(60, to: "6")   // hidden: the left panel shows 7
        #expect(!s.isOnAnotherDisplay(10, than: CGPoint(x: 100, y: 500)))
        #expect(s.isOnAnotherDisplay(60, than: CGPoint(x: 100, y: 500)))
        #expect(!s.isOnAnotherDisplay(60, than: CGPoint(x: -100, y: 500)))
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
