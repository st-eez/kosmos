import CoreGraphics
import Testing
@testable import KosmosCore

// Steve's desk, less the built-in display: the left panel and the main panel.
private let leftPanel = Monitor(id: 1, frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080))
private let mainPanel = Monitor(id: 2, frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))

/// A movement: the window under the pointer, the pointer's x, left of 0 on the left panel,
/// and whether Control is held.
private typealias Movement = (window: WindowID, x: CGFloat, control: Bool)

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
        let desktop: WindowID = 5
        #expect(entered([(7, 100, false), (desktop, -100, false), (desktop, -200, false), (desktop, 100, false)])
            == [into(7, display: 2), into(desktop, display: 1), nil, into(desktop, display: 2)])
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
        // A command focused window 9 and moved the pointer there from window 7. It landed in
        // window 9, or over window 8 beside it: either way focus stays.
        for landed: UInt32 in [9, 8] {
            var gate = gate()
            #expect(entered([(7, 100, false)], gate: &gate) == [into(7, display: 2)])
            gate.warped()
            #expect(entered([(landed, 1500, false), (landed, 1510, false), (7, 100, false)], gate: &gate)
                == [nil, nil, into(7)])
        }
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
    _ = s.add(2, floating: true)
    _ = s.add(3)
    _ = s.park([3], because: .fullscreen)
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
        #expect(skip(1, key: .noWindow) == nil)
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

    @Test func aWindowIsVisibleOnTheWorkspaceAnyDisplayShows() {
        // The main panel shows workspace 1 and has the focus; the left panel shows 5.
        var s = Session(names: ["1", "2", "5", "6"], monitors: [mainPanel, leftPanel], assigned: ["1": 2, "2": 2, "5": 1, "6": 1])
        _ = s.add(10)
        _ = s.add(20, to: "2")
        _ = s.add(50, to: "5")
        _ = s.add(60, to: "6")
        #expect(s.isVisible(10) && s.isVisible(50))
        #expect(!s.isVisible(20) && !s.isVisible(60))   // hidden workspaces
        #expect(!s.isVisible(99))   // unknown
    }

    @Test func onToTheDesktopOfADisplayShowingAnEmptyWorkspaceThatWorkspaceTakesFocus() {
        // Workspace 1 on the main panel has the focus and a window; the left panel shows
        // empty workspace 7.
        var s = Session(names: ["1", "6", "7"], monitors: [mainPanel, leftPanel], assigned: ["1": 2, "6": 1, "7": 1])
        _ = s.add(10)
        _ = s.add(60, to: "6")
        _ = s.perform(.workspace(.named("7")))
        _ = s.perform(.workspace(.named("1")))
        let settings = settings()
        #expect(s.workspace(shownOn: 1) == "7")
        #expect(settings.emptyWorkspace(entered: 1, overDesktop: true, in: s) == "7")
        // A window Kosmos does not manage covers the left panel: a slideshow, a game, the
        // menu bar or a panel over a native fullscreen window.
        #expect(settings.emptyWorkspace(entered: 1, overDesktop: false, in: s) == nil)
        // Back on the main panel, over a gap or the desktop: its workspace has a window.
        #expect(settings.emptyWorkspace(entered: 2, overDesktop: true, in: s) == nil)
        // Workspace 7 focused already, or focus follows mouse off.
        var focused = s
        _ = focused.perform(.workspace(.named("7")))
        #expect(settings.emptyWorkspace(entered: 1, overDesktop: true, in: focused) == nil)
        #expect(FocusFollowsMouse().emptyWorkspace(entered: 1, overDesktop: true, in: s) == nil)
        // The left panel showing workspace 6, which has a window, keeps focus where it is.
        _ = s.perform(.workspace(.named("6")))
        _ = s.perform(.workspace(.named("1")))
        #expect(settings.emptyWorkspace(entered: 1, overDesktop: true, in: s) == nil)
    }

    @Test func theDesktopIsFindersDesktopWindowOrTheWallpaperBelowIt() {
        // Levels WindowServer listed on macOS 27: Finder's desktop windows, the wallpaper,
        // the display backstop, SketchyBar, and a panel, a menu and a slideshow above them.
        #expect(FocusFollowsMouse.isDesktop(level: -2147483603))
        #expect(FocusFollowsMouse.isDesktop(level: -2147483624))
        #expect(FocusFollowsMouse.isDesktop(level: -2147483626))
        #expect(!FocusFollowsMouse.isDesktop(level: -20))
        for level in [CGWindowLevelForKey(.normalWindow), CGWindowLevelForKey(.popUpMenuWindow),
                      CGWindowLevelForKey(.mainMenuWindow), CGWindowLevelForKey(.screenSaverWindow)] {
            #expect(!FocusFollowsMouse.isDesktop(level: level))
        }
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

private func command(_ binding: String) throws -> Command {
    try Command.parse(binding.split(separator: " ").map(String.init)).get()
}

private let commandTab = ActivationInput(key: 0.2, leftClick: 3600, rightClick: 3600, moved: 4)
/// In a window unless it landed on the Dock.
private let leftClick = ActivationInput(key: 30, leftClick: 0.3, rightClick: 3600, moved: 0.05)

/// The user's input as the pointer rule reads it, and the readings it took.
private final class Input {
    enum Reading { case display, leftButton, activation }

    var focusOnAnotherDisplay = false
    var leftButtonDown = false
    var activation = (input: leftClick, onDock: false)
    var read: [Reading] = []

    var readings: PointerReadings {
        PointerReadings(focusOnAnotherDisplay: { self.read.append(.display); return self.focusOnAnotherDisplay },
                        leftButtonDown: { self.read.append(.leftButton); return self.leftButtonDown },
                        activation: { self.read.append(.activation); return self.activation })
    }

    func moves(after change: FocusChange, mouseFollowsFocus: Bool = true) -> Bool {
        change.movesPointer(mouseFollowsFocus: mouseFollowsFocus, reading: readings)
    }
}

/// Whether mouse-follows-focus moves the pointer for a command as a binding writes it.
private func movesPointer(_ binding: String, from source: CommandSource = .hotkey, toAnotherDisplay: Bool = false,
                          mouseFollowsFocus: Bool = true) throws -> Bool {
    let input = Input()
    input.focusOnAnotherDisplay = toAnotherDisplay
    return try input.moves(after: .command(command(binding), from: source), mouseFollowsFocus: mouseFollowsFocus)
}

/// Over workspace 1 of the `desk()` below.
private let pointerOnMainPanel = CGPoint(x: 100, y: 500)

/// Workspace 1 has the focus and windows 10 and 11. The left panel shows workspace 5, with
/// window 50, and hides empty workspace 7.
private func desk() -> Session {
    var s = Session(names: ["1", "5", "7"], monitors: [mainPanel, leftPanel], assigned: ["1": 2, "5": 1, "7": 1])
    _ = s.add(10)
    _ = s.add(11)
    _ = s.add(50, to: "5")
    _ = s.perform(.workspace(.named("5")))
    _ = s.perform(.workspace(.named("1")))
    return s
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

    @Test func mouseFollowsFocusOffLeavesThePointer() throws {
        for binding in ["focus left", "move right", "workspace 2", "move-node-to-workspace 3"] {
            #expect(try !movesPointer(binding, toAnotherDisplay: true, mouseFollowsFocus: false), "\(binding)")
        }
        let input = Input()
        input.activation = (commandTab, false)
        for change in [FocusChange.admission(.adopt, atLaunch: false), .keyReport(admitted: true), .keyReport(admitted: false),
                       .returned(followed: true)] {
            #expect(!input.moves(after: change, mouseFollowsFocus: false), "\(change)")
        }
        #expect(input.read.isEmpty)
    }

    @Test func onlyAWorkspaceCommandReadsWhereThePointerIs() throws {
        let input = Input()
        for (binding, source, on) in [("workspace 2", CommandSource.cli, true), ("workspace 2", .hotkey, false),
                                      ("focus left", .hotkey, true), ("join-with left", .hotkey, true)] {
            _ = try input.moves(after: .command(command(binding), from: source), mouseFollowsFocus: on)
        }
        #expect(input.read.isEmpty)
        _ = try input.moves(after: .command(command("workspace 2"), from: .hotkey))
        #expect(input.read == [.display])
    }

    @Test func aNewWindowItsAppKeyedBringsThePointer() {
        let input = Input()
        #expect(input.moves(after: .admission(.adopt, atLaunch: false)))
        #expect(input.read == [.leftButton])
        // At startup the pointer stays put. A window its app has not keyed yet, or one on a
        // hidden workspace, waits for its key report.
        #expect(!input.moves(after: .admission(.adopt, atLaunch: true)))
        for focus in [AdmissionFocus.none, .awaitKey, .placedHidden] {
            #expect(!input.moves(after: .admission(focus, atLaunch: false)), "\(focus)")
        }
        #expect(input.read == [.leftButton])
        // A native tab dragged out of its group, with the drag still on.
        input.leftButtonDown = true
        #expect(!input.moves(after: .admission(.adopt, atLaunch: false)))
    }

    @Test func aKeyReportOfANewWindowBringsThePointerUnlessTheLeftButtonIsDown() {
        // Whatever input came before, as a launch keys its first window seconds after the
        // launcher's hotkey.
        let input = Input()
        #expect(input.moves(after: .keyReport(admitted: true)))
        input.leftButtonDown = true
        #expect(!input.moves(after: .keyReport(admitted: true)))
        #expect(input.read == [.leftButton, .leftButton])
    }

    @Test func commandTabOrADockClickBringsThePointerToTheWindowMacOSKeyed() {
        // A key report Kosmos adopts or follows, and a return Kosmos follows.
        for change in [FocusChange.keyReport(admitted: false), .returned(followed: true)] {
            let input = Input()
            // A click in the window, on a bar pill or on a link that opens another app.
            #expect(!input.moves(after: change), "\(change)")
            input.activation = (commandTab, false)
            #expect(input.moves(after: change), "\(change)")
            input.activation = (leftClick, true)
            #expect(input.moves(after: change), "\(change)")
            #expect(input.read == [.activation, .activation, .activation], "\(change)")
        }
    }

    @Test func aReturnKosmosDoesNotFollowLeavesThePointer() {
        // A command came after the return, or Kosmos follows none of the windows.
        let input = Input()
        input.activation = (commandTab, false)
        #expect(!input.moves(after: .returned(followed: false)))
        #expect(input.read.isEmpty)
    }

    @Test func aSwitchToTheWorkspaceAnotherDisplayShowsBringsThePointerThere() throws {
        // Each reaches workspace 5 on the left panel with nothing shown or hidden, and a tile
        // reflowed under the pointer would take focus on the next bump.
        for binding in ["workspace 5", "workspace-back-and-forth", "move-node-to-workspace --focus-follows-window 5"] {
            var s = desk()
            let command = try command(binding)
            let result = s.perform(command)
            let plan = try #require(result, "\(binding)")
            #expect(plan.show.isEmpty && plan.hide.isEmpty, "\(binding)")
            #expect(s.focusedWorkspace == "5" && s.focusIsOnAnotherDisplay(than: pointerOnMainPanel), "\(binding)")
            #expect(try movesPointer(binding, toAnotherDisplay: true), "\(binding)")
            let window = try #require(s.focused, "\(binding)")
            let frame = try #require(s.frames(of: s.focusedWorkspace)[window], "\(binding)")
            #expect(leftPanel.frame.contains(CGPoint(x: frame.midX, y: frame.midY)), "\(binding)")
        }
    }

    @Test func keyboardFocusOnAnEmptyWorkspaceOfAnotherDisplayGoesToThatDisplay() throws {
        // Empty workspace 7 is on the left panel. With no window to center on, the pointer
        // goes to the display's center.
        var shown = desk()
        _ = shown.perform(.workspace(.named("7")))
        _ = shown.perform(.workspace(.named("1")))
        for (start, binding) in [(desk(), "workspace 7"), (shown, "focus-monitor left")] {
            var s = start
            let command = try command(binding)
            #expect(s.perform(command) != nil, "\(binding)")
            #expect(s.focusedWorkspace == "7" && s.focused == nil, "\(binding)")
            #expect(s.focusIsOnAnotherDisplay(than: pointerOnMainPanel), "\(binding)")
            #expect(try movesPointer(binding, toAnotherDisplay: true), "\(binding)")
            #expect(s.monitor(of: s.focusedWorkspace) == leftPanel, "\(binding)")
        }
    }

    @Test func aSwitchOnThePointersDisplayLeavesThePointer() throws {
        var s = desk()
        _ = s.perform(.workspace(.named("5")))
        #expect(s.focusIsOnAnotherDisplay(than: pointerOnMainPanel))
        _ = s.perform(.workspace(.named("1")))
        #expect(!s.focusIsOnAnotherDisplay(than: pointerOnMainPanel))
    }

    @Test func thePointerGoesToTheFrameKosmosWrites() throws {
        // A move sets no focus. The pointer follows the window to the tile the plan writes,
        // on this display or another, so nothing is read from WindowServer.
        var s = desk()
        s.adopt(10)
        let before = s.frames(of: "1")
        let result = s.perform(.move(.right))
        let plan = try #require(result)
        #expect(s.focused == 10 && plan.focus == nil)
        #expect(s.frames(of: s.focusedWorkspace)[10] == plan.frames[10])
        #expect(plan.frames[10] == before[11])
        let moved = s.perform(try command("move-node-to-monitor --focus-follows-window left"))
        let across = try #require(moved)
        #expect(s.focused == 10 && s.focusedWorkspace == "5")
        #expect(s.frames(of: s.focusedWorkspace)[10] == across.frames[10])
    }

    @Test func commandTabAndADockClickBringThePointerToTheAppTheyPick() {
        let never = 3600.0
        // Command-Tab, or a launcher's hotkey, with the pointer at rest since.
        #expect(ActivationInput(key: 0.2, leftClick: never, rightClick: never, moved: 4).bringsPointer(onDock: false))
        // The pointer moved after the key, as when the app activated itself later.
        #expect(!ActivationInput(key: 0.2, leftClick: never, rightClick: never, moved: 0.1).bringsPointer(onDock: true))
        // Teams clicked in the Dock, and the pointer already on its way up.
        let click = ActivationInput(key: 30, leftClick: 0.3, rightClick: never, moved: 0.05)
        #expect(click.bringsPointer(onDock: true))
        // The same click in a window, on a bar pill or on a link that opens another app.
        #expect(!click.bringsPointer(onDock: false))
        // A Dock click over a second ago, or a key or a right click since.
        for input in [ActivationInput(key: 30, leftClick: 1.5, rightClick: never, moved: 1),
                      ActivationInput(key: 0.1, leftClick: 0.3, rightClick: never, moved: 0.05),
                      ActivationInput(key: 30, leftClick: 0.3, rightClick: 0.2, moved: 0.05)] {
            #expect(!input.bringsPointer(onDock: true))
        }
    }
}
