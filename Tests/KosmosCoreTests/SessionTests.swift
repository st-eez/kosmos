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

/// `list-bindings` describes every binding's amount, and a trap there would stop Kosmos.
@Test func resizeAmountsAreFiniteAndAtMost100000Points() {
    #expect(Command.parse(["resize", "smart", "+100000"]) == .success(.resize(.smart, by: 100_000)))
    #expect(Command.parse(["resize", "width", "-0.5"]) == .success(.resize(.width, by: -0.5)))
    for amount in ["+inf", "-inf", "+nan", "+1e20", "-1e19", "+100000.5", "-100001"] {
        guard case .failure = Command.parse(["resize", "smart", amount]) else {
            Issue.record("accepted \(amount)")
            continue
        }
    }
}

@Test func aCommandNamingAWorkspaceTheProfileLeavesOutFails() {
    // The laptop profile lists 1 to 5; `workspace 6` exited 0 and did nothing.
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
    // Within the workspace, the root goes into a new root along the direction.
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
    _ = s.park([2])
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

// MARK: Returning windows (DESIGN.md, section 5.5)

@Test func aReturningWindowTakesKosmosToItsWorkspace() {
    var s = session()
    _ = s.add(1)
    _ = s.park([1])   // minimized on workspace 1
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
    _ = s.park([2])
    let plan = s.unpark([2], follow: 2)
    #expect(plan.show.isEmpty && plan.hide.isEmpty && plan.focus == nil)
    #expect(plan.frames.count == 2)
    #expect(s.focused == 2)
}

@Test func anAppsWindowsParkAndReturnTogether() {
    var s = session()
    _ = s.add(1); _ = s.add(2); _ = s.add(3)
    let before = s.frames(of: "1")
    #expect(s.park([1, 3]).frames == [2: display])
    #expect(s.isParked(1) && s.isParked(3) && !s.isParked(2))
    #expect(s.unpark([3, 1], follow: 1).frames == before)
    #expect(!s.isParked(1) && !s.isParked(3))
    #expect(s.unpark([9], follow: 9).isEmpty)
}

@Test func parkedWindowsSitOutSwitches() {
    var s = session()
    _ = s.add(1); _ = s.add(2)
    _ = s.park([1])
    #expect(s.perform(.workspace(.named("2")))?.hide == [2])
    #expect(s.perform(.workspace(.named("1")))?.show == [2])
    let plan = s.unpark([1], follow: 1)
    #expect(plan.show.isEmpty && plan.hide.isEmpty)
}

@Test func anAppsWindowsOnOtherHiddenWorkspacesStayConcealed() {
    var s = session()
    _ = s.add(1)
    _ = s.add(3, to: "3")
    _ = s.park([1, 3])
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
    _ = s.park([1])   // minimized on workspace 1
    _ = s.perform(.workspace(.named("2")))
    _ = s.add(2)
    let plan = s.unpark([1], follow: nil)
    #expect(s.focusedWorkspace == "2")
    #expect(plan.hide == [1])   // back on workspace 1, which is hidden
    #expect(plan.show.isEmpty && plan.focus == nil)
    #expect(s.focused == 2)
}

@Test func aReturnNotFollowedKeepsTheShownWorkspacesFocus() {
    var s = session()
    _ = s.add(1); _ = s.add(2)
    s.adopt(2)
    _ = s.park([2])   // Kosmos focused 1 again without a report
    let plan = s.unpark([2], follow: nil)
    #expect(s.focused == 1)   // though 2 was focused more recently
    #expect(plan.focus == nil)
}

@Test func aReturnNotFollowedIntoAnEmptyShownWorkspaceIsFocused() {
    var s = session()
    _ = s.add(1)
    _ = s.park([1])
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
    _ = s.park([1])   // minimized
    _ = s.park([2])   // hidden with A
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
    _ = s.park([1, 2])   // hidden with their app
    #expect(s.followOnUnhide([1, 2], keyed: 2, fallback: 1) == 2)
    // A dialog Kosmos does not manage, or no key window: the most recently focused one.
    #expect(s.followOnUnhide([1, 2], keyed: 99, fallback: 1) == 1)
    #expect(s.followOnUnhide([1, 2], keyed: nil, fallback: 1) == 1)
}

@Test func aWindowAdmittedParkedWaitsForItsOwnReturn() {
    #expect(ParkReason.atAdmission(fullscreen: false, minimized: false, appHidden: false) == nil)
    #expect(ParkReason.atAdmission(fullscreen: false, minimized: true, appHidden: false) == .minimized)
    #expect(ParkReason.atAdmission(fullscreen: false, minimized: false, appHidden: true) == .appHidden)
    // A minimized window of a hidden app stays minimized when the app unhides, and a
    // fullscreen one returns when it leaves fullscreen.
    #expect(ParkReason.atAdmission(fullscreen: false, minimized: true, appHidden: true) == .minimized)
    #expect(ParkReason.atAdmission(fullscreen: true, minimized: false, appHidden: true) == .fullscreen)
}

@Test func aWindowConcealedWhenItParkedIsRevealedOnTheShownWorkspace() {
    // An app with a window on each workspace hides, Kosmos shows the hidden workspace, and
    // the app comes back keyed on the window there.
    var s = session()
    _ = s.add(1)
    _ = s.add(2, to: "2")   // concealed
    _ = s.park([1, 2])
    _ = s.perform(.workspace(.named("2")))
    let plan = s.unpark([1, 2], follow: 2)
    #expect(s.focusedWorkspace == "2")
    #expect(plan.show == [2])
    #expect(plan.hide == [1])
}

// MARK: Native tabs (DESIGN.md, section 5.5)

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
    // Back to the first tab: the same place again.
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
    // A tab that holds no place changes nothing.
    #expect(s.replace(42, with: 5) == nil)
    #expect(s.replace(8, with: 8) == nil)
}

@Test func aParkedWindowReturnsBesideTheTabThatReplacedItsNeighbour() {
    var s = session()
    _ = s.add(1); _ = s.add(2); _ = s.add(3)
    let before = s.frames(of: "1"), order = s.windows(of: "1")
    _ = s.park([3])           // minimized, remembering the windows it stood among
    _ = s.replace(2, with: 7)  // 2's tab group switched tabs
    _ = s.unpark([3], follow: nil)
    #expect(s.windows(of: "1") == order.map { $0 == 2 ? 7 : $0 })
    #expect(s.frames(of: "1")[3] == before[3])
}

@Test func aWindowParkedWhenItBecameATabJoinsItsGroupsPlace() {
    // Merge All Windows orders 2 out with no tab coming in, and Kosmos parks it as closed
    // by its app. Selecting its tab later brings it to the group's place.
    var s = session()
    _ = s.add(1); _ = s.add(2); _ = s.add(3)
    _ = s.park([2])
    let before = s.frames(of: "1"), order = s.windows(of: "1")
    _ = s.replace(3, with: 2)
    #expect(!s.isParked(2) && s.workspace(of: 3) == nil)
    #expect(s.windows(of: "1") == order.map { $0 == 3 ? 2 : $0 })
    #expect(s.frames(of: "1")[2] == before[3])
}

@Test func aTabParkedAsClosedBeforeItsSwitchTookEffectGivesTheNewTabItsPlace() {
    // Tab 2 was parked as closed by its app a second after it was deselected, before tab 7's
    // admission let the switch take effect. Its place returns for tab 7, which is on screen
    // (Controller.tabSwitched).
    var s = session()
    _ = s.add(1, to: "2"); _ = s.add(2, to: "2")
    let before = s.frames(of: "2"), order = s.windows(of: "2")
    _ = s.park([2])
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
    _ = s.park([2])   // tab 2 entered native fullscreen
    _ = s.perform(.workspace(.named("2")))
    let plan = s.replace(2, with: 7)!
    #expect(s.isParked(7) && s.workspace(of: 2) == nil)
    #expect(plan.hide.isEmpty && plan.frames[7] == nil)   // parked: no conceal, no frame
    #expect(s.minimums[7] == nil)                           // no display-sized minimum
    // Leaving fullscreen, tab 7 returns where tab 2 stood.
    _ = s.perform(.workspace(.named("1")))
    _ = s.unpark([7], follow: 7)
    #expect(s.frames(of: "1")[7] == before[2])
}

@Test func aTabInheritsTheMinimumOfTheTabItReplaces() {
    // Tabs share a size: without it, every switch in a tight layout would reflow twice, as
    // the new tab refuses its share and Kosmos learns the minimum again.
    var s = session()
    _ = s.add(1); _ = s.add(2)
    _ = s.setMinimum(2, CGSize(width: 700, height: 0))
    let before = s.frames(of: "1")
    let plan = s.replace(2, with: 7)!
    #expect(s.minimums[7] == CGSize(width: 700, height: 0) && s.minimums[2] == nil)
    #expect(plan.frames[7] == before[2])
}
