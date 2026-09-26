import CoreGraphics
import Testing
@testable import KosmosCore

private let display = CGRect(x: 0, y: 0, width: 1000, height: 800)

private func session(_ names: [String] = ["1", "2", "3"]) -> Session {
    Session(names: names, display: display)
}

@Test func aCommandNamingAWorkspaceTheProfileLeavesOutFails() {
    let s = session(["1", "2", "3", "4", "5"])
    #expect(s.missingWorkspace(in: .workspace(.named("6"))) == "6")
    #expect(s.missingWorkspace(in: .moveNodeToWorkspace(.named("0"), focusFollowsWindow: true)) == "0")
    #expect(s.missingWorkspace(in: .workspace(.named("5"))) == nil)
    #expect(s.missingWorkspace(in: .moveNodeToWorkspace(.named("2"), focusFollowsWindow: false, window: 42)) == nil)
    #expect(s.missingWorkspace(in: .workspace(.next)) == nil)
    #expect(s.missingWorkspace(in: .focus(.left)) == nil)
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

@Test func aWindowARuleFloatsKeepsTheFrameItsAppGaveIt() {
    var s = session()
    _ = s.add(1); _ = s.add(2)
    s.adopt(2)
    let tiles = s.frames(of: "1")
    let plan = s.add(3, floating: true)
    #expect(plan.frames == tiles)
    #expect(s.workspaces["1"]!.tree == "h[1 2]" && s.workspaces["1"]!.floating == [3])
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
    let back = s.perform(.workspaceBackAndForth)!
    #expect(back.show.count == 2)
    #expect(back.focus == .window(2))
}

@Test func switchToAnEmptyWorkspaceFocusesNothing() {
    var s = session()
    _ = s.add(1)
    #expect(s.perform(.workspace(.named("3")))?.focus == .noWindow)
}

@Test func switchToTheShownWorkspaceDoesNothing() {
    var s = session()
    #expect(s.perform(.workspace(.named("1"))) == nil)
    #expect(s.perform(.workspace(.named("nope"))) == nil)
}

@Test func nextAndPreviousWrapAround() {
    var s = session()
    #expect(s.perform(.workspace(.previous)) != nil)
    #expect(s.focusedWorkspace == "3")
    _ = s.perform(.workspace(.next))
    #expect(s.focusedWorkspace == "1")
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
    #expect(s.focusedWorkspace == "2")
    #expect(plan.hide == [1])
    #expect(plan.show.isEmpty)
    #expect(plan.focus == .window(2))
}

@Test func followSwitchesToAHiddenWindowsWorkspace() {
    var s = session()
    _ = s.add(1)
    _ = s.add(5, to: "2")
    let plan = s.follow(5)
    #expect(s.focusedWorkspace == "2")
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

@Test func moveAtTheEdgeOfTheWorkspaceWrapsTheRootOnlyWithinIt() {
    var s = session()
    _ = s.add(1); _ = s.add(2)
    s.adopt(2)
    // With one display, wrapping comes back to it, and the window stays.
    #expect(s.perform(.move(.up, boundaries: .allMonitorsWrapping)) == nil)
    #expect(s.workspaces["1"]!.tree == "h[1 2]")
    #expect(s.perform(.move(.up)) != nil)
    #expect(s.workspaces["1"]!.tree == "v[2 1]")
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
    #expect(s.focusedWorkspace == "3")
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
    _ = s.park([2], because: .minimized)
    #expect(s.perform(.moveNodeToWorkspace(.named("2"), focusFollowsWindow: false, window: 2)) == nil)
    #expect(s.workspace(of: 2) == "1")
}

@Test func observedMinimumsShapeTheLayout() {
    var s = session()
    _ = s.add(1); _ = s.add(2)
    let plan = s.setMinimum(2, CGSize(width: 700, height: 100))
    #expect(plan.frames[1] == CGRect(x: 0, y: 0, width: 300, height: 800))
    #expect(plan.frames[2] == CGRect(x: 300, y: 0, width: 700, height: 800))
    #expect(s.setMinimum(2, CGSize(width: 600, height: 50)).isEmpty)   // no larger
    #expect(s.setMinimum(2, CGSize(width: 600, height: 200)).frames.count == 2)
    #expect(s.minimums[2] == CGSize(width: 700, height: 200))
    #expect(s.setMinimum(9, CGSize(width: 10, height: 10)).isEmpty)   // unknown window
}

@Test func aWindowSeenBelowItsMinimumLosesItOnThatAxis() {
    var s = session()
    _ = s.add(1); _ = s.add(2)
    _ = s.setMinimum(2, CGSize(width: 900, height: 700))
    #expect(s.sizeObserved(2, CGSize(width: 899, height: 700)).isEmpty)   // within the slack
    #expect(s.sizeObserved(1, CGSize(width: 10, height: 10)).isEmpty)     // no minimum
    let plan = s.sizeObserved(2, CGSize(width: 495, height: 800))
    #expect(plan.frames[1] == CGRect(x: 0, y: 0, width: 500, height: 800))
    #expect(plan.frames[2] == CGRect(x: 500, y: 0, width: 500, height: 800))
    #expect(s.minimums[2] == CGSize(width: 0, height: 700))
    _ = s.sizeObserved(2, CGSize(width: 495, height: 600))
    #expect(s.minimums[2] == nil)
}

@Test func resizeStopsAtAnObservedMinimum() {
    var s = session()
    _ = s.add(1); _ = s.add(2)
    s.adopt(1)
    _ = s.setMinimum(2, CGSize(width: 400, height: 0))
    #expect(s.perform(.resize(.width, by: 300))?.frames[2]!.width == 400)
    #expect(s.perform(.resize(.width, by: 50)) == nil)
}

@Test func removingAWindowForgetsItsMinimum() {
    var s = session()
    _ = s.add(1)
    _ = s.setMinimum(1, CGSize(width: 900, height: 0))
    _ = s.remove(1)
    #expect(s.minimums.isEmpty)
}

@Test func aWorkspaceWithWindowsAlwaysHasFocus() {
    var s = session()
    _ = s.add(1); _ = s.add(2)
    #expect(s.focused == 1)   // no focus report yet, and commands still have a target
    #expect(s.perform(.focus(.right))?.focus == .window(2))
    _ = s.add(7, to: "3")
    _ = s.perform(.workspace(.named("3")))
    #expect(s.focused == 7)
}

// MARK: Returning windows (docs/tree.md)

@Test func aReturningWindowTakesKosmosToItsWorkspace() {
    var s = session()
    _ = s.add(1)
    _ = s.park([1], because: .minimized)
    _ = s.perform(.workspace(.named("2")))
    _ = s.add(2)
    let plan = s.unpark([1], follow: 1)
    #expect(s.focusedWorkspace == "1")
    #expect(plan.show == [1])
    #expect(plan.hide == [2])
    #expect(plan.focus == .window(1))
    #expect(plan.frames[1] == display)
}

@Test func followingAWindowOfTheShownWorkspaceSwitchesNothing() {
    var s = session()
    _ = s.add(1); _ = s.add(2)
    s.adopt(1)
    _ = s.park([2], because: .minimized)
    let plan = s.unpark([2], follow: 2)
    #expect(plan.show.isEmpty && plan.hide.isEmpty && plan.focus == nil)
    #expect(plan.frames.count == 2)
    #expect(s.focused == 2)
}

@Test func anAppsWindowsParkAndReturnTogether() {
    var s = session()
    _ = s.add(1); _ = s.add(2); _ = s.add(3)
    let before = s.frames(of: "1")
    #expect(s.park([1, 3], because: .appHidden).frames == [2: display])
    #expect(s.isParked(1) && s.isParked(3) && !s.isParked(2))
    #expect(s.unpark([3, 1], follow: 1).frames == before)
    #expect(!s.isParked(1) && !s.isParked(3))
    #expect(s.unpark([9], follow: 9).isEmpty)
}

@Test func parkedWindowsSitOutSwitches() {
    var s = session()
    _ = s.add(1); _ = s.add(2)
    _ = s.park([1], because: .minimized)
    #expect(s.perform(.workspace(.named("2")))?.hide == [2])
    #expect(s.perform(.workspace(.named("1")))?.show == [2])
    let plan = s.unpark([1], follow: 1)
    #expect(plan.show.isEmpty && plan.hide.isEmpty)
}

@Test func anAppsWindowsOnOtherHiddenWorkspacesStayConcealed() {
    var s = session()
    _ = s.add(1)
    _ = s.add(3, to: "3")
    _ = s.park([1, 3], because: .appHidden)
    _ = s.perform(.workspace(.named("2")))
    _ = s.add(2)
    let plan = s.unpark([1, 3], follow: 1)
    #expect(s.focusedWorkspace == "1")
    #expect(plan.show == [1])
    #expect(Set(plan.hide) == [2, 3])
}

@Test func aReturnAfterACommandLeavesKosmosWhereTheCommandTookIt() {
    var s = session()
    _ = s.add(1)
    _ = s.park([1], because: .minimized)
    _ = s.perform(.workspace(.named("2")))
    _ = s.add(2)
    let plan = s.unpark([1], follow: nil)
    #expect(s.focusedWorkspace == "2")
    #expect(plan.hide == [1])
    #expect(plan.show.isEmpty && plan.focus == nil)
    #expect(s.focused == 2)
}

@Test func aReturnNotFollowedKeepsTheShownWorkspacesFocus() {
    var s = session()
    _ = s.add(1); _ = s.add(2)
    s.adopt(2)
    _ = s.park([2], because: .minimized)
    let plan = s.unpark([2], follow: nil)
    #expect(s.focused == 1)   // though 2 was focused more recently
    #expect(plan.focus == nil)
}

@Test func aReturnNotFollowedIntoAnEmptyShownWorkspaceIsFocused() {
    var s = session()
    _ = s.add(1)
    _ = s.park([1], because: .minimized)
    #expect(s.focused == nil)
    let plan = s.unpark([1], follow: nil)
    #expect(s.focused == 1)
    #expect(plan.focus == .window(1))
}

@Test func aKeyedWindowThatDidNotHideWithItsAppIsNotFollowedWithIt() {
    // App A has 1 minimized on workspace 1 and 2 on workspace 2, and hides. Clicking 1's
    // Dock thumbnail unhides A and keys 1, which returns on its own.
    var s = session()
    _ = s.add(1)
    _ = s.add(2, to: "2")
    _ = s.park([1], because: .minimized)
    _ = s.park([2], because: .appHidden)
    _ = s.perform(.workspace(.named("3")))
    let follow = s.followOnUnhide([2], keyed: 1, fallback: 2)
    #expect(follow == nil)
    let plan = s.unpark([2], follow: follow)
    #expect(s.focusedWorkspace == "3")
    #expect(plan.hide == [2] && plan.show.isEmpty)
    #expect(s.isParked(1))
}

@Test func anUnhiddenAppIsFollowedToTheWindowItKeys() {
    var s = session()
    _ = s.add(1)
    _ = s.add(2, to: "2")
    _ = s.park([1, 2], because: .appHidden)
    #expect(s.followOnUnhide([1, 2], keyed: 2, fallback: 1) == 2)
    // A dialog Kosmos does not manage, or no key window: the most recently focused one.
    #expect(s.followOnUnhide([1, 2], keyed: 99, fallback: 1) == 1)
    #expect(s.followOnUnhide([1, 2], keyed: nil, fallback: 1) == 1)
}

@Test func aWindowAdmittedParkedWaitsForItsOwnReturn() {
    #expect(ParkReason.atAdmission(fullscreen: false, minimized: false, appHidden: false) == nil)
    #expect(ParkReason.atAdmission(fullscreen: false, minimized: true, appHidden: false) == .minimized)
    #expect(ParkReason.atAdmission(fullscreen: false, minimized: false, appHidden: true) == .appHidden)
    #expect(ParkReason.atAdmission(fullscreen: false, minimized: true, appHidden: true) == .minimized)
    #expect(ParkReason.atAdmission(fullscreen: true, minimized: false, appHidden: true) == .fullscreen)
}

@Test func aWindowConcealedWhenItParkedIsRevealedOnTheShownWorkspace() {
    var s = session()
    _ = s.add(1)
    _ = s.add(2, to: "2")
    _ = s.park([1, 2], because: .appHidden)
    _ = s.perform(.workspace(.named("2")))
    let plan = s.unpark([1, 2], follow: 2)
    #expect(s.focusedWorkspace == "2")
    #expect(plan.show == [2])
    #expect(plan.hide == [1])
}

@Test func aReopenedWindowOpensOnTheFocusedWorkspace() {
    var s = session()
    _ = s.perform(.workspace(.named("3")))
    _ = s.add(3)
    _ = s.setMinimum(3, CGSize(width: 600, height: 400))
    _ = s.park([3], because: .closedByApp)
    _ = s.perform(.workspace(.named("2")))
    let plan = s.reopen(3, to: nil, floating: false)
    #expect(s.workspace(of: 3) == "2" && !s.isParked(3) && s.windows(of: "3").isEmpty)
    #expect(plan?.frames == [3: display] && plan?.show == [] && plan?.hide == [])
    #expect(s.focused == 3 && s.focusedWorkspace == "2")
    #expect(s.minimums[3] == CGSize(width: 600, height: 400))
    #expect(s.reopen(3, to: nil, floating: false) == nil)
}

@Test func aReopenedWindowTakesItsRulesWorkspaceAndIsConcealedOrRevealed() {
    var s = session()
    _ = s.add(1)
    _ = s.add(2, to: "2")   // concealed, then closed and kept
    _ = s.park([2], because: .closedByApp)
    var plan = s.reopen(2, to: "3", floating: true)
    #expect(s.workspace(of: 2) == "3" && s.workspaces["3"]!.floating == [2] && s.windows(of: "2").isEmpty)
    #expect(plan?.hide == [2] && plan?.show == [])
    _ = s.park([2], because: .closedByApp)
    plan = s.reopen(2, to: nil, floating: false)
    #expect(s.workspace(of: 2) == "1" && plan?.show == [2] && plan?.hide == [])
    #expect(plan?.frames[1] != nil && plan?.frames[2] != nil)
}

// MARK: Native tabs (docs/tree.md)

@Test func aSelectedTabTakesThePlaceOfTheTabItReplaces() {
    var s = session()
    _ = s.add(1); _ = s.add(2); _ = s.add(3)
    s.adopt(2)
    let before = s.frames(of: "1"), order = s.windows(of: "1")
    let plan = s.replace(2, with: 7)!
    #expect(s.workspace(of: 7) == "1" && s.workspace(of: 2) == nil)
    #expect(s.windows(of: "1") == order.map { $0 == 2 ? 7 : $0 })
    #expect(s.focused == 7)
    #expect(plan.frames[7] == before[2] && plan.frames[1] == before[1] && plan.frames[3] == before[3])
    #expect(plan.show.isEmpty && plan.hide.isEmpty && plan.focus == nil)
    _ = s.replace(7, with: 2)
    #expect(s.frames(of: "1") == before)
}

@Test func aNewTabTiledAsAWindowOfItsOwnJoinsItsGroupsPlace() {
    var s = session()
    _ = s.add(1); _ = s.add(2)
    let before = s.frames(of: "1")
    _ = s.add(9)   // admitted before its switch was seen
    let plan = s.replace(2, with: 9)!
    #expect(s.windows(of: "1") == [1, 9])
    #expect(plan.frames[9] == before[2] && plan.frames[1] == before[1])
}

@Test func aTabOnAHiddenWorkspaceStaysConcealed() {
    var s = session()
    _ = s.add(1)
    _ = s.add(2, to: "2")
    #expect(s.replace(2, with: 8)?.hide == [8])
    #expect(s.replace(42, with: 5) == nil)
    #expect(s.replace(8, with: 8) == nil)
}

@Test func aParkedWindowReturnsBesideTheTabThatReplacedItsNeighbour() {
    var s = session()
    _ = s.add(1); _ = s.add(2); _ = s.add(3)
    let before = s.frames(of: "1"), order = s.windows(of: "1")
    _ = s.park([3], because: .minimized)
    _ = s.replace(2, with: 7)   // 2's tab group switched tabs
    _ = s.unpark([3], follow: nil)
    #expect(s.windows(of: "1") == order.map { $0 == 2 ? 7 : $0 })
    #expect(s.frames(of: "1")[3] == before[3])
}

@Test func aWindowParkedWhenItBecameATabJoinsItsGroupsPlace() {
    // Merge All Windows orders 2 out with no tab coming in, so it parks as closed and kept.
    var s = session()
    _ = s.add(1); _ = s.add(2); _ = s.add(3)
    _ = s.park([2], because: .closedByApp)
    let before = s.frames(of: "1"), order = s.windows(of: "1")
    _ = s.replace(3, with: 2)
    #expect(!s.isParked(2) && s.workspace(of: 3) == nil)
    #expect(s.windows(of: "1") == order.map { $0 == 3 ? 2 : $0 })
    #expect(s.frames(of: "1")[2] == before[3])
}

@Test func aTabParkedAsClosedBeforeItsSwitchTookEffectGivesTheNewTabItsPlace() {
    // Tab 2 parked as closed and kept before tab 7's admission let the switch take effect
    // (Controller.tabSwitched).
    var s = session()
    _ = s.add(1, to: "2"); _ = s.add(2, to: "2")
    let before = s.frames(of: "2"), order = s.windows(of: "2")
    _ = s.park([2], because: .closedByApp)
    _ = s.unpark([2], follow: nil)
    let plan = s.replace(2, with: 7)!
    #expect(!s.isParked(7) && s.workspace(of: 7) == "2")
    #expect(s.windows(of: "2") == order.map { $0 == 2 ? 7 : $0 })
    #expect(plan.hide == [7] && plan.frames[7] == before[2])
}

@Test func aTabSwitchInsideANativeFullscreenGroupSwapsTheParkedTab() {
    var s = session()
    _ = s.add(1); _ = s.add(2)
    let before = s.frames(of: "1")
    _ = s.setMinimum(2, CGSize(width: 1000, height: 800))   // read back while in fullscreen
    _ = s.park([2], because: .fullscreen)
    _ = s.perform(.workspace(.named("2")))
    let plan = s.replace(2, with: 7)!
    #expect(s.isParked(7) && s.workspace(of: 2) == nil)
    #expect(plan.hide.isEmpty && plan.frames[7] == nil)
    #expect(s.minimums[7] == nil)
    _ = s.perform(.workspace(.named("1")))
    _ = s.unpark([7], follow: 7)
    #expect(s.frames(of: "1")[7] == before[2])
}

@Test func aTabInheritsTheMinimumOfTheTabItReplaces() {
    var s = session()
    _ = s.add(1); _ = s.add(2)
    _ = s.setMinimum(2, CGSize(width: 700, height: 0))
    let before = s.frames(of: "1")
    let plan = s.replace(2, with: 7)!
    #expect(s.minimums[7] == CGSize(width: 700, height: 0) && s.minimums[2] == nil)
    #expect(plan.frames[7] == before[2])
}

@Test func aWindowOnScreenThatARevealedWorkspaceTakesInEntersIt() {
    var s = session()
    _ = s.add(1); _ = s.add(2)
    _ = s.add(3, to: "2")
    // Workspace 2's window is concealed; the moved window is on screen.
    let concealed: (WindowID) -> Bool = { s.workspace(of: $0) == "2" && $0 != 2 && $0 != 4 }
    let shown: (WindowID) -> DisplayID? = { _ in s.monitors[0].id }
    var probe = s
    let follow = probe.perform(.moveNodeToWorkspace(.named("2"), focusFollowsWindow: true, window: 2))!
    #expect(probe.entering(show: follow.show, hide: follow.hide, frames: follow.frames.keys, concealed: concealed, display: shown) == [2])
    // Into an empty workspace, and without following, nothing is revealed around it.
    probe = s
    let empty = probe.perform(.moveNodeToWorkspace(.named("3"), focusFollowsWindow: true, window: 2))!
    #expect(probe.entering(show: empty.show, hide: empty.hide, frames: empty.frames.keys, concealed: concealed, display: shown).isEmpty)
    probe = s
    let stay = probe.perform(.moveNodeToWorkspace(.named("2"), focusFollowsWindow: false, window: 2))!
    #expect(probe.entering(show: stay.show, hide: stay.hide, frames: stay.frames.keys, concealed: concealed, display: shown).isEmpty)
    // A plain switch reveals only concealed windows.
    probe = s
    let plain = probe.perform(.workspace(.named("2")))!
    #expect(probe.entering(show: plain.show, hide: plain.hide, frames: plain.frames.keys, concealed: concealed, display: shown).isEmpty)
    // A rule window opened on screen for workspace 2 and followed there.
    _ = s.add(4, to: "2")
    let rule = s.follow(4)
    #expect(s.entering(show: rule.show, hide: rule.hide, frames: rule.frames.keys, concealed: concealed, display: shown) == [4])
}
