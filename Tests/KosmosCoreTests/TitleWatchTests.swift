import CoreGraphics
import Testing
@testable import KosmosCore

/// Steve's rules for Chrome: the Bitwarden pop-out floats, and every other Chrome window goes
/// to workspace 2.
private let popOut = WindowRule(appID: "com.google.Chrome", title: "Bitwarden", float: true)
private let chrome = WindowRule(appID: "com.google.Chrome", workspace: "2")
private let rules = [popOut, chrome]
private let admitted = ContinuousClock.now
private let shown = CGRect(x: 300, y: 200, width: 400, height: 600)

private func first(_ title: String?) -> WindowRule? {
    rules.first { $0.matches(appID: "com.google.Chrome", appName: "Google Chrome", title: title) }
}

/// Window 7 admitted as Chrome showed it, under the title of the window it came from.
private func popOutWatch() -> TitleWatch {
    var watch = TitleWatch()
    watch.admitted(7, rule: first("NetSuite Login - Google Chrome"), frame: shown, at: admitted)
    return watch
}

@Suite struct TitleWatchTests {
    @Test func onlyTheNewWindowsOfAnAppARuleOnTheTitleNamesAreWatched() {
        #expect(TitleWatch.watches(rules, appID: "com.google.Chrome", appName: "Google Chrome"))
        #expect(!TitleWatch.watches(rules, appID: "net.imput.helium", appName: "Helium"))
        #expect(!TitleWatch.watches([chrome], appID: "com.google.Chrome", appName: "Google Chrome"))
    }

    /// Chrome titled the pop-out "Bitwarden" about 0.6 s after it showed (docs/config.md).
    @Test func aRuleOnTheTitleThatMatchesOnlyOnceTheAppRetitledTheWindowApplies() throws {
        var watch = popOutWatch()
        let now = admitted + .milliseconds(450)
        let result = watch.retitled(7, rule: first("Bitwarden"), at: now)
        let applied = try #require(result)
        #expect(applied.rule == popOut)
        #expect(applied.watch.frame == shown && applied.watch.rule == chrome)
        // Once.
        #expect(watch.retitled(7, rule: first("Bitwarden"), at: now) == nil)
    }

    @Test func aTitleThatLeavesTheRuleThatPlacedTheWindowChangesNothing() {
        var watch = popOutWatch()
        #expect(watch.retitled(7, rule: first("Inbox - Google Chrome"), at: admitted + .milliseconds(300)) == nil)
        // Helium titles its pop-out at once, so the rule on the title placed it.
        watch.admitted(8, rule: first("Bitwarden"), frame: shown, at: admitted)
        #expect(watch.retitled(8, rule: first("Bitwarden"), at: admitted + .milliseconds(300)) == nil)
        #expect(watch.retitled(8, rule: first("Settings - Google Chrome"), at: admitted + .milliseconds(400)) == nil)
        // The watches go on.
        #expect(watch.retitled(7, rule: first("Bitwarden"), at: admitted + .milliseconds(500)) != nil)
    }

    @Test func aTitleAfterTheBoundChangesNothing() {
        var watch = popOutWatch()
        #expect(watch.retitled(7, rule: first("Bitwarden"), at: admitted + TitleWatch.bound + .milliseconds(1)) == nil)
        #expect(watch.retitled(7, rule: first("Bitwarden"), at: admitted + .milliseconds(100)) == nil)
        var edge = popOutWatch()
        #expect(edge.retitled(7, rule: first("Bitwarden"), at: admitted + TitleWatch.bound) != nil)
    }

    @Test func aWindowTheUserPlacedKeepsItsPlace() {
        for command in [Command.move(.left), .swap(.right), .joinWith(.up), .layout(.toggleFloating), .layout(.toggleOrientation),
                        .fullscreen, .resize(.width, by: 50), .balanceSizes, .flattenWorkspaceTree,
                        .moveNodeToWorkspace(.named("3"), focusFollowsWindow: false),
                        .moveNodeToMonitor(.next, focusFollowsWindow: true, wrapAround: false)] {
            var watch = popOutWatch()
            watch.ran(command, focused: 7)
            #expect(watch.retitled(7, rule: first("Bitwarden"), at: admitted + .milliseconds(500)) == nil, "\(command)")
        }
        var named = popOutWatch()
        named.ran(.moveNodeToWorkspace(.named("3"), focusFollowsWindow: false, window: 7), focused: 9)
        #expect(named.retitled(7, rule: first("Bitwarden"), at: admitted + .milliseconds(500)) == nil)
        var dragged = popOutWatch()
        dragged.end(7)
        #expect(dragged.retitled(7, rule: first("Bitwarden"), at: admitted + .milliseconds(500)) == nil)
    }

    @Test func commandsThatMoveNoWindowOrAnotherLeaveTheWatch() {
        for (command, focused) in [(Command.focus(.left), WindowID(7)), (.workspace(.named("3")), 7), (.workspaceBackAndForth, 7),
                                   (.focusMonitor(.next, wrapAround: false), 7), (.reloadConfig, 7), (.profile("home"), 7),
                                   (.focusFollowsMouse(.toggle), 7), (.move(.left), 9),
                                   (.moveNodeToWorkspace(.named("3"), focusFollowsWindow: false, window: 9), 7)] {
            var watch = popOutWatch()
            watch.ran(command, focused: focused)
            #expect(watch.retitled(7, rule: first("Bitwarden"), at: admitted + .milliseconds(500)) != nil, "\(command)")
        }
    }
}

private let display = CGRect(x: 0, y: 0, width: 1000, height: 800)

@Suite struct RetitledTests {
    @Test func aWindowFloatedLateGoesBackToWhereItsAppShowedIt() throws {
        var s = Session(names: ["1", "2"], display: display)
        _ = s.add(1)
        _ = s.add(7)
        let result = s.retitled(7, floating: true, frame: shown, to: nil)
        let plan = try #require(result)
        #expect(s.isFloating(7) && s.workspace(of: 7) == "1")
        #expect(plan.frames == [1: display, 7: shown])
        #expect(plan.show.isEmpty && plan.hide.isEmpty && plan.focus == nil)
    }

    @Test func aWindowTiledLateTakesATile() throws {
        var s = Session(names: ["1", "2"], display: display)
        _ = s.add(1)
        _ = s.add(7, floating: true)
        let result = s.retitled(7, floating: false, frame: shown, to: nil)
        let plan = try #require(result)
        #expect(!s.isFloating(7))
        #expect(plan.frames.count == 2 && plan.frames[7] != shown)
    }

    @Test func theFocusFollowsAWindowWithItToItsRulesWorkspace() throws {
        var s = Session(names: ["1", "2"], display: display)
        _ = s.add(1)
        _ = s.add(7)
        _ = s.adopt(7)
        let result = s.retitled(7, floating: true, frame: shown, to: "2")
        let plan = try #require(result)
        #expect(s.workspace(of: 7) == "2" && s.isFloating(7) && s.focusedWorkspace == "2")
        // It stays on screen as its workspace takes the display.
        #expect(plan.hide == [1] && plan.show.isEmpty && plan.focus == .window(7))
        #expect(plan.frames[7] == shown)
    }

    @Test func aWindowWithoutTheFocusGoesAlone() throws {
        var s = Session(names: ["1", "2"], display: display)
        _ = s.add(1)
        _ = s.add(7)
        _ = s.adopt(1)
        let result = s.retitled(7, floating: false, frame: shown, to: "2")
        let plan = try #require(result)
        #expect(s.workspace(of: 7) == "2" && s.focusedWorkspace == "1")
        #expect(plan.hide == [7] && plan.show.isEmpty)
        #expect(plan.frames[1] == display)
    }

    @Test func aParkedWindowOrOneAlreadyAsTheRuleSaysChangesNothing() {
        var s = Session(names: ["1", "2"], display: display)
        _ = s.add(7, to: "2", floating: true)
        #expect(s.retitled(7, floating: true, frame: shown, to: "2") == nil)
        #expect(s.retitled(7, floating: true, frame: shown, to: "9") == nil)
        _ = s.park([7], because: .minimized)
        #expect(s.retitled(7, floating: false, frame: shown, to: "1") == nil)
        #expect(s.retitled(8, floating: true, frame: shown, to: nil) == nil)
    }
}
