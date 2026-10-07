import CoreGraphics
import Testing
@testable import KosmosCore

/// The agent workspace (docs/displays.md), on Desk's three displays: 1 to 4 on main, 5 to 7 on
/// left, 8 to 0 on the built-in display.
@Suite struct AgentWorkspaceTests {
    private let agent = Session.agent

    @Test func everySessionHasItAndNoDisplayTakesItUnasked() {
        var s = Desk.session()
        #expect(s.names.last == agent)
        #expect(!s.isShown(agent))
        s.reconfigure(names: ["1", "2"], monitors: [Desk.main, Desk.left, Desk.builtIn], assigned: [:], merge: [:])
        #expect(s.names == ["1", "2", agent])
        #expect(!s.shownWorkspaces.contains(agent))
    }

    @Test func itShowsOnTheFocusedDisplayAndGoesBackAtTheSameKey() throws {
        var s = Desk.session()
        _ = s.add(10, to: "1"); _ = s.add(20, to: agent)
        let shownPlan = s.perform(.workspace(.named(agent)))
        let shown = try #require(shownPlan)
        #expect(s.workspace(shownOn: Desk.main.id) == agent && s.focusedWorkspace == agent)
        #expect(shown.hide == [10] && shown.show == [20] && shown.focus == .window(20))
        let backPlan = s.perform(.workspace(.named(agent)))
        let back = try #require(backPlan)
        #expect(s.workspace(shownOn: Desk.main.id) == "1" && s.focusedWorkspace == "1")
        #expect(back.hide == [20] && back.show == [10] && back.focus == .window(10))
        #expect(!s.isShown(agent))
    }

    @Test func fromAnotherDisplayItMovesHereAndGivesThatDisplayItsWorkspaceBack() throws {
        var s = Desk.session()
        _ = s.add(10, to: "1"); _ = s.add(50, to: "5"); _ = s.add(20, to: agent)
        _ = s.perform(.workspace(.named(agent)))
        _ = s.perform(.focusMonitor(.direction(.left), wrapAround: false))
        #expect(s.focusedWorkspace == "5")
        let movedPlan = s.perform(.workspace(.named(agent)))
        let moved = try #require(movedPlan)
        #expect(s.workspace(shownOn: Desk.left.id) == agent && s.workspace(shownOn: Desk.main.id) == "1")
        #expect(s.focusedWorkspace == agent)
        // On screen before and after: neither concealed nor revealed.
        #expect(moved.hide == [50] && moved.show == [10])
    }

    @Test func aDisplaySwitchedAwayFromItForgetsWhatItDisplaced() throws {
        var s = Desk.session()
        _ = s.perform(.workspace(.named(agent)))
        _ = s.perform(.workspace(.named("2")))
        _ = s.perform(.workspace(.named(agent)))
        _ = s.perform(.workspace(.named(agent)))
        #expect(s.workspace(shownOn: Desk.main.id) == "2")
    }

    @Test func itsWindowsFloatAndTileOnceTheyLeave() throws {
        var s = Desk.session()
        _ = s.add(30, to: agent)
        #expect(s.isFloating(30))
        _ = s.add(10, to: "1")
        _ = s.perform(.moveNodeToWorkspace(.named(agent), focusFollowsWindow: false, window: 10))
        #expect(s.isFloating(10))
        _ = s.perform(.moveNodeToWorkspace(.named("2"), focusFollowsWindow: false, window: 30))
        #expect(!s.isFloating(30))
    }

    @Test func aWindowMovedBetweenItAndAHiddenWorkspaceIsConcealedAgain() throws {
        var s = Desk.session()
        _ = s.add(40, to: "2")
        let intoPlan = s.perform(.moveNodeToWorkspace(.named(agent), focusFollowsWindow: false, window: 40))
        let into = try #require(intoPlan)
        #expect(into.hide == [40] && into.show.isEmpty)
        let outPlan = s.perform(.moveNodeToWorkspace(.named("3"), focusFollowsWindow: false, window: 40))
        let out = try #require(outPlan)
        #expect(out.hide == [40] && out.show.isEmpty)
    }

    @Test func nextAndPreviousLeaveItOut() throws {
        var s = Desk.session()
        _ = s.perform(.workspace(.named("4")))
        _ = s.perform(.workspace(.next))
        #expect(s.focusedWorkspace == "1")
        _ = s.perform(.workspace(.named(agent)))
        _ = s.perform(.workspace(.next))
        #expect(s.focusedWorkspace != agent && s.workspace(shownOn: Desk.main.id) != agent)
    }

    @Test func theBarHasItOnlyWhileADisplayShowsIt() {
        var s = Session(names: ["1", "2"], display: CGRect(x: 0, y: 0, width: 1000, height: 800))
        let display = BarSnapshot.Display(id: 1, name: "Built-in")
        func names() -> [String] {
            s.barSnapshot(profile: nil, displays: [1: display], app: { _ in nil }, frame: { _ in nil }).workspaces.map(\.name)
        }
        #expect(names() == ["1", "2"])
        _ = s.perform(.workspace(.named(agent)))
        #expect(names() == ["1", "2", agent])
    }

    @Test func aRuleCanSendWindowsThereAndTheConfigCannotListIt() {
        let rule = Config.load("config-version = 1\nworkspaces = ['1']\n[[rule]]\napp-id = 'com.example'\nworkspace = 'agent'\n")
        #expect(rule.diagnostics.isEmpty)
        let listed = Config.load("config-version = 1\nworkspaces = ['1', 'agent']\n")
        #expect(listed.config == nil)
        #expect(listed.diagnostics.map(\.description).contains { $0.contains("Kosmos's own workspace") })
    }
}

@Test func aWindowItsAppRaisesStaysFloatingThereAndOnceItLeaves() {
    var s = Desk.session()
    _ = s.add(30, to: Session.agent)
    #expect(s.leveled(30, raised: true) == nil)
    _ = s.perform(.moveNodeToWorkspace(.named("2"), focusFollowsWindow: false, window: 30))
    #expect(s.isFloating(30))
    _ = s.leveled(30, raised: false)
    #expect(!s.isFloating(30))
    _ = s.add(40, to: "1"); _ = s.leveled(40, raised: true)
    _ = s.perform(.moveNodeToWorkspace(.named(Session.agent), focusFollowsWindow: false, window: 40))
    _ = s.leveled(40, raised: false)
    #expect(s.isFloating(40))
}

@Test func aClickOnAnotherDisplaysDesktopFocusesItsWorkspace() throws {
    var s = Desk.session()
    #expect(s.focusedDisplay == Desk.main.id)
    let onFocused = s.clickedDesktop(at: CGPoint(x: 500, y: 500))
    let onBuiltIn = s.clickedDesktop(at: CGPoint(x: 600, y: 1500))
    #expect(!onFocused && onBuiltIn)
    #expect(s.focusedDisplay == Desk.builtIn.id)
    _ = s.perform(.workspace(.named(Session.agent)))
    #expect(s.workspace(shownOn: Desk.builtIn.id) == Session.agent)
    let offEvery = s.clickedDesktop(at: CGPoint(x: 5000, y: 5000))
    #expect(!offEvery)
}

@Test func aWindowDroppedOnTheAgentWorkspaceFloatsWhereItWasLeft() throws {
    var s = Desk.session()
    _ = s.perform(.focusMonitor(.direction(.left), wrapAround: false))
    _ = s.perform(.workspace(.named(Session.agent)))
    _ = s.perform(.focusMonitor(.direction(.right), wrapAround: false))
    _ = s.add(10, to: "1"); _ = s.add(11, to: "1")
    _ = s.lift(10)
    let plan = s.drop(at: CGPoint(x: -900, y: 500))
    #expect(s.workspace(of: 10) == Session.agent && s.isFloating(10))
    #expect(plan.frames[10] == nil)
    // Raised and lowered by its app, it stays floating there.
    _ = s.leveled(10, raised: true); _ = s.leveled(10, raised: false)
    #expect(s.isFloating(10))
    #expect(s.validate().isEmpty)
}

@Test func aTiledWindowTheUserLeftThereFloatsWhenItsAppRaisesIt() {
    var s = Desk.session()
    _ = s.add(30, to: Session.agent)
    _ = s.perform(.workspace(.named(Session.agent)))
    _ = s.perform(.layout(.toggleFloating))
    #expect(!s.isFloating(30))
    let raised = s.leveled(30, raised: true)
    #expect(raised != nil && s.isFloating(30))
    #expect(s.validate().isEmpty)
}

@Test func itsDisplayLeavingWhileFocusedKeepsWhatItDisplacedOnMain() {
    var s = Desk.session([:])
    _ = s.perform(.workspace(.named("1")))
    _ = s.perform(.focusMonitor(.direction(.left), wrapAround: false))
    let left = s.focusedWorkspace
    _ = s.perform(.workspace(.named(Session.agent)))
    let main = s.workspace(shownOn: Desk.main.id)!
    s.reconfigure(names: Desk.names, monitors: [Desk.main], assigned: [:], merge: [:])
    #expect(s.workspace(shownOn: Desk.main.id) == Session.agent)
    _ = s.perform(.workspace(.named(Session.agent)))
    #expect(s.workspace(shownOn: Desk.main.id) == main && main != left)
}

@Test func thePointerFocusesItWhereItIsAndNeverMovesIt() throws {
    var s = Desk.session()
    _ = s.perform(.focusMonitor(.direction(.left), wrapAround: false))
    _ = s.perform(.workspace(.named(Session.agent)))
    _ = s.perform(.focusMonitor(.direction(.right), wrapAround: false))
    let main = try #require(s.workspace(shownOn: Desk.main.id))
    let plan = s.focusShownWorkspace(Session.agent)
    #expect(plan?.focus == .noWindow)
    #expect(s.workspace(shownOn: Desk.left.id) == Session.agent && s.workspace(shownOn: Desk.main.id) == main)
    #expect(s.focusedWorkspace == Session.agent)
    let again = s.focusShownWorkspace(Session.agent)
    let hidden = s.focusShownWorkspace("6")
    #expect(again == nil && hidden == nil)
}

@Test func anAgentsWindowUnminimizedWithNoFollowStaysConcealedThere() {
    var s = Desk.session()
    _ = s.add(30, to: Session.agent)
    _ = s.park([30], because: .minimized)
    let plan = s.unpark([30], follow: nil)
    #expect(plan.hide == [30] && !s.isShown(Session.agent))
    #expect(s.focusedWorkspace == "1")
}
