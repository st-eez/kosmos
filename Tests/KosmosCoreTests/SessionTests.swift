import CoreGraphics
import Testing
@testable import KosmosCore

private let display = CGRect(x: 0, y: 0, width: 1000, height: 800)

private func session(_ names: [String] = ["1", "2", "3"]) -> Session {
    Session(names: names, display: display)
}

@Test func parsesSteveBindings() {
    let cases: [([String], Command)] = [
        (["workspace", "2"], .workspace(.named("2"))),
        (["workspace", "next"], .workspace(.next)),
        (["workspace-back-and-forth"], .workspaceBackAndForth),
        (["focus", "left"], .focus(.left)),
        (["move", "down"], .move(.down)),
        (["join-with", "up"], .joinWith(.up)),
        (["move-node-to-workspace", "--focus-follows-window", "prev"], .moveNodeToWorkspace(.previous, focusFollowsWindow: true)),
        (["move-node-to-workspace", "3"], .moveNodeToWorkspace(.named("3"), focusFollowsWindow: false)),
        (["move-node-to-workspace", "--window-id", "42", "5"], .moveNodeToWorkspace(.named("5"), focusFollowsWindow: false, window: 42)),
        (["layout", "tiles", "horizontal", "vertical"], .layout(.toggleOrientation)),
        (["layout", "floating", "tiling"], .layout(.toggleFloating)),
        (["fullscreen"], .fullscreen),
        (["resize", "smart", "+100"], .resize(.smart, by: 100)),
        (["resize", "width", "-50"], .resize(.width, by: -50)),
        (["flatten-workspace-tree"], .flattenWorkspaceTree),
        (["reload-config"], .reloadConfig),
        (["mode", "resize"], .mode("resize")),
    ]
    for (arguments, command) in cases {
        #expect(Command.parse(arguments) == .success(command), "\(arguments)")
    }
}

@Test func rejectsWhatItDoesNotKnow() {
    for arguments in [[], ["focus"], ["focus", "sideways"], ["resize", "smart", "100"], ["resize", "smart", "+0"],
                      ["fullscreen", "--no-outer-gaps"], ["layout", "accordion"], ["move-node-to-workspace"],
                      ["workspace", "1", "2"], ["exec-and-forget", "true"], ["mode"], ["mode", "a", "b"],
                      ["move-node-to-workspace", "--window-id", "x", "2"], ["move-node-to-workspace", "--window-id"]] {
        guard case .failure = Command.parse(arguments) else {
            Issue.record("accepted \(arguments)")
            continue
        }
    }
}

@Test func newWindowsJoinTheShownWorkspaceAndGetFrames() {
    var s = session()
    let plan = s.add(1)
    #expect(plan.frames == [1: display])
    #expect(plan.hide.isEmpty)
    #expect(s.workspace(of: 1) == "1")
    let second = s.add(2)
    #expect(second.frames.count == 2)
}

@Test func windowForAHiddenWorkspaceIsConcealed() {
    var s = session()
    let plan = s.add(7, to: "3")
    #expect(plan.hide == [7])
    #expect(s.workspace(of: 7) == "3")
}

@Test func switchShowsAndHidesAndFocusesTheWorkspaceMRU() {
    var s = session()
    _ = s.add(1); _ = s.add(2)
    s.adopt(2)
    _ = s.add(3, to: "2")
    let plan = s.perform(.workspace(.named("2")))!
    #expect(Set(plan.hide) == [1, 2])
    #expect(plan.show == [3])
    #expect(plan.focus == .window(3))
    // Back again: the old workspace remembers its focus.
    let back = s.perform(.workspaceBackAndForth)!
    #expect(back.show.count == 2)
    #expect(back.focus == .window(2))
}

@Test func switchToAnEmptyWorkspaceFocusesNothing() {
    var s = session()
    _ = s.add(1)
    #expect(s.perform(.workspace(.named("3")))?.focus == KeyWindow.none)
}

@Test func switchToTheShownWorkspaceDoesNothing() {
    var s = session()
    #expect(s.perform(.workspace(.named("1"))) == nil)
    #expect(s.perform(.workspace(.named("nope"))) == nil)
}

@Test func nextAndPreviousWrapAround() {
    var s = session()
    #expect(s.perform(.workspace(.previous)) != nil)
    #expect(s.visible == "3")
    _ = s.perform(.workspace(.next))
    #expect(s.visible == "1")
}

@Test func moveNodeToWorkspaceConcealsTheWindowAndFocusesTheNextOne() {
    var s = session()
    _ = s.add(1); _ = s.add(2)
    s.adopt(1); s.adopt(2)
    let plan = s.perform(.moveNodeToWorkspace(.named("2"), focusFollowsWindow: false))!
    #expect(plan.hide == [2])
    #expect(plan.focus == .window(1))
    #expect(plan.frames[1] == display)
    #expect(s.workspace(of: 2) == "2")
}

@Test func moveNodeWithFocusFollowingSwitchesWithTheWindow() {
    var s = session()
    _ = s.add(1); _ = s.add(2)
    s.adopt(2)
    let plan = s.perform(.moveNodeToWorkspace(.next, focusFollowsWindow: true))!
    #expect(s.visible == "2")
    #expect(plan.hide == [1])
    #expect(plan.show.isEmpty)
    #expect(plan.focus == .window(2))
}

@Test func followSwitchesToAHiddenWindowsWorkspace() {
    var s = session()
    _ = s.add(1)
    _ = s.add(5, to: "2")
    let plan = s.follow(5)
    #expect(s.visible == "2")
    #expect(plan.focus == .window(5))
    #expect(plan.hide == [1])
}

@Test func removingTheFocusedWindowFocusesTheNext() {
    var s = session()
    _ = s.add(1); _ = s.add(2)
    s.adopt(1); s.adopt(2)
    let plan = s.remove(2)
    #expect(plan.focus == .window(1))
    #expect(plan.frames == [1: display])
    #expect(s.remove(2).isEmpty)
}

@Test func parkedWindowsLeaveTheLayoutAndReturn() {
    var s = session()
    _ = s.add(1); _ = s.add(2)
    #expect(s.park(2).frames == [1: display])
    #expect(s.unpark(2).frames.count == 2)
}

@Test func treeCommandsActOnTheFocusedWindow() {
    var s = session()
    _ = s.add(1); _ = s.add(2)
    s.adopt(2)
    #expect(s.perform(.focus(.left))?.focus == .window(1))
    #expect(s.perform(.focus(.left)) == nil)   // at the edge
    let toggled = s.perform(.layout(.toggleOrientation))!
    #expect(toggled.frames[1]!.width == display.width)
    #expect(s.perform(.fullscreen)?.frames.values.contains(display) == true)
}

@Test func commandsOnAnEmptyWorkspaceDoNothing() {
    var s = session()
    #expect(s.perform(.focus(.left)) == nil)
    #expect(s.perform(.moveNodeToWorkspace(.named("2"), focusFollowsWindow: false)) == nil)
}

@Test func moveNodeByWindowIdFromTheShownWorkspace() {
    var s = session()
    _ = s.add(1); _ = s.add(2)
    s.adopt(2)
    let plan = s.perform(.moveNodeToWorkspace(.named("3"), focusFollowsWindow: false, window: 1))!
    #expect(plan.hide == [1])
    #expect(plan.focus == nil)   // the focused window stayed
    #expect(s.workspace(of: 1) == "3")
    #expect(plan.frames[2] == display)
}

@Test func moveNodeByWindowIdIntoTheShownWorkspaceShowsIt() {
    var s = session()
    _ = s.add(1)
    _ = s.add(7, to: "2")
    let plan = s.perform(.moveNodeToWorkspace(.named("1"), focusFollowsWindow: false, window: 7))!
    #expect(plan.show == [7])
    #expect(plan.hide.isEmpty)
    #expect(s.workspace(of: 7) == "1")
    #expect(plan.frames.count == 2)
}

@Test func moveNodeBetweenHiddenWorkspacesTouchesNothingOnScreen() {
    var s = session()
    _ = s.add(7, to: "2")
    let plan = s.perform(.moveNodeToWorkspace(.named("3"), focusFollowsWindow: false, window: 7))!
    #expect(plan.show.isEmpty && plan.hide.isEmpty && plan.focus == nil)
    #expect(s.workspace(of: 7) == "3")
}

@Test func followingAWindowFromAHiddenWorkspaceRevealsIt() {
    var s = session()
    _ = s.add(1)
    _ = s.add(7, to: "2")
    let plan = s.perform(.moveNodeToWorkspace(.named("3"), focusFollowsWindow: true, window: 7))!
    #expect(s.visible == "3")
    #expect(plan.show == [7])      // concealed on 2, it must be revealed on 3
    #expect(plan.hide == [1])
    #expect(plan.focus == .window(7))
}

@Test func movedFloatingWindowKeepsFloating() {
    var s = session()
    _ = s.add(1); _ = s.add(2)
    s.adopt(2)
    _ = s.perform(.layout(.toggleFloating))
    _ = s.perform(.moveNodeToWorkspace(.named("2"), focusFollowsWindow: false))
    #expect(s.workspaces["2"]!.floating == [2])
    #expect(s.frames(of: "2").isEmpty)   // floating windows get no tile
}

@Test func minimizedWindowCannotBeMovedIntoATile() {
    var s = session()
    _ = s.add(1); _ = s.add(2)
    _ = s.park(2)
    #expect(s.perform(.moveNodeToWorkspace(.named("2"), focusFollowsWindow: false, window: 2)) == nil)
    #expect(s.workspace(of: 2) == "1")
}
