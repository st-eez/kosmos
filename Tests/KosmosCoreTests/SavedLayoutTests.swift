import CoreGraphics
import Foundation
import Testing
@testable import KosmosCore

extension Session {
    /// Puts `description`'s tree on workspace `name`, its windows focused in tree order.
    mutating func place(_ description: String, on name: String) {
        var workspace = Workspace(description)
        for window in workspace.root.windows {
            home[window] = name
            workspace.focus(window)
        }
        workspaces[name] = workspace
    }

    /// Every window with a place, in workspace order.
    var placed: [WindowID] { names.flatMap(allWindows(of:)) }
}

/// Everything a restart should bring back on one workspace.
private func sameLayout(_ a: Workspace, _ b: Workspace) -> Bool {
    a.sameTree(as: b) && Set(a.floating) == Set(b.floating) && Set(a.parked.map(\.window)) == Set(b.parked.map(\.window))
        && a.fullscreenWindow == b.fullscreenWindow && a.focusedWindow == b.focusedWindow
}

@Suite struct SavedLayoutTests {
    /// Steve's windows at his desk: the main panel shows 1 and has the focus, the left panel
    /// shows 6 and the built-in display 8. ChatGPT and Claude (20, 21) are on hidden 2, with
    /// 21 minimized, Chrome floats on 4, and 81 floated from its tile on 8.
    static func desk() -> Session {
        var s = Desk.session()
        s.place("h[1:2 v[2 h[3 4:3]]:3 5:1]", on: "1")
        s.place("h[20 21:2]", on: "2")
        _ = s.add(40, to: "4", floating: true)
        _ = s.add(41, to: "4", floating: true)
        s.place("v[60 61:3]", on: "6")
        s.place("h[80:3 81 82]", on: "8")
        _ = s.park([21], because: .minimized)
        s.workspaces["6"]!.toggleFullscreen(61)
        s.workspaces["8"]!.float(81)
        _ = s.perform(.workspace(.named("6")))
        _ = s.perform(.workspace(.named("1")))
        s.workspaces["1"]!.focus(3)
        return s
    }

    static func roundTrip(_ layout: SavedLayout) throws -> SavedLayout {
        try JSONDecoder().decode(SavedLayout.self, from: JSONEncoder().encode(layout))
    }

    static func restored(_ layout: SavedLayout, monitors: [Monitor] = [Desk.builtIn, Desk.main, Desk.left],
                         assigned: [String: DisplayID] = Desk.home, names: [String] = Desk.names) -> Session {
        var s = Session(names: names, monitors: monitors, assigned: assigned)
        s.restore(layout)
        return s
    }

    @Test(arguments: 0..<24 as Range<UInt64>)
    func aRestartPutsEveryWindowBackInAnyOrder(seed: UInt64) throws {
        let before = Self.desk()
        var after = Self.restored(try Self.roundTrip(before.savedLayout()))
        #expect(after.shownWorkspaces == ["6", "1", "8"] && after.focusedWorkspace == "1")
        var random = SplitMix64(state: seed)
        for window in before.placed.shuffled(using: &random) {
            _ = after.add(window, parked: before.parkReason(of: window))
        }
        for name in Desk.names {
            #expect(sameLayout(after.workspaces[name]!, before.workspaces[name]!), "\(name): \(after.workspaces[name]!.detailed)")
        }
        #expect(after.focused == 3)
        // The minimized window goes back to its place.
        _ = after.unpark([21], follow: nil)
        #expect(after.workspaces["2"]!.sameTree(as: Workspace("h[20 21:2]")))
    }

    /// A window floated from its tile floats again, and `layout tiling` returns it to its
    /// saved place.
    @Test func aWindowFloatingWhenSavedTilesBackToItsPlace() throws {
        var before = Session(names: ["a"], monitors: [Desk.main])
        before.place("h[1:3 v[2 3] 4]", on: "a")
        before.workspaces["a"]!.float(2)
        var after = Session(names: ["a"], monitors: [Desk.main])
        after.restore(try Self.roundTrip(before.savedLayout()))
        for window in [3, 2, 4, 1] as [WindowID] { _ = after.add(window) }
        #expect(after.workspaces["a"]!.floating == [2] && after.workspaces["a"]!.sameTree(as: before.workspaces["a"]!))
        after.workspaces["a"]!.tile(2)
        #expect(after.workspaces["a"]!.sameTree(as: Workspace("h[1:3 v[2 3] 4]")))
    }

    @Test(arguments: permutations([1, 2, 3, 4, 5] as [WindowID]))
    func everyOrderOfArrivalRebuildsTheTree(order: [WindowID]) throws {
        var before = Session(names: ["a"], monitors: [Desk.main])
        before.place("h[1:2 v[2 h[3 4:3]]:3 5:1]", on: "a")
        var after = Session(names: ["a"], monitors: [Desk.main])
        after.restore(try Self.roundTrip(before.savedLayout()))
        for window in order { _ = after.add(window) }
        #expect(after.workspaces["a"]!.sameTree(as: before.workspaces["a"]!), "\(after.workspaces["a"]!.detailed)")
    }

    /// Each window back takes the tile it had, whatever the order, so no window on screen
    /// moves at the restart. A window that closes before it is back gives its tile up.
    @Test(arguments: permutations([1, 2, 3, 4] as [WindowID]))
    func theWindowsBackHoldTheirTilesForTheRest(order: [WindowID]) {
        var before = Session(names: ["a"], monitors: [Desk.main])
        before.place("h[1:2 v[2 3] 4]", on: "a")
        _ = before.add(5)
        _ = before.park([5], because: .minimized)
        let tiles = before.frames(of: "a")
        var after = Session(names: ["a"], monitors: [Desk.main])
        after.restore(before.savedLayout())
        for window in order.dropLast() {
            #expect(after.add(window).frames == tiles.filter { after.workspace(of: $0.key) != nil })
        }
        let closed = order.last!
        let plan = after.forgetPending { $0 == closed }
        _ = before.remove(closed)
        #expect(plan.frames == before.frames(of: "a"))
    }

    /// During the hold a focus or a swap in a direction goes by the tiles on screen, where 1
    /// spans only 3 and 4 below it, though 5 was focused later.
    @Test func aFocusDuringTheHoldGoesByTheTilesOnScreen() {
        var before = Session(names: ["a"], monitors: [Desk.main])
        before.place("v[h[1 2] h[3 4 5]]", on: "a")
        before.workspaces["a"]!.focus(1)
        var after = Session(names: ["a"], monitors: [Desk.main])
        after.restore(before.savedLayout())
        for window in [1, 3, 4, 5] as [WindowID] { _ = after.add(window) }
        var focusing = after
        #expect(focusing.perform(.focus(.down))?.focus == .window(4))
        _ = after.perform(.swap(.down))
        #expect(after.workspaces["a"]!.tree == "v[4 h[3 1 5]]")
    }

    /// A window Kosmos did not know changes the tree, and the tiles held for the saved windows
    /// go to the windows on screen.
    @Test func aNewWindowEndsTheHold() {
        var before = Session(names: ["a"], monitors: [Desk.main])
        before.place("h[1 2 3]", on: "a")
        var after = Session(names: ["a"], monitors: [Desk.main])
        after.restore(before.savedLayout())
        _ = after.add(1)
        #expect(after.frames(of: "a")[1]!.width < 700)
        #expect(after.add(9).frames.keys.sorted() == [1, 9])
        #expect(after.frames(of: "a")[1]!.width > 900)
    }

    /// Windows that closed while Kosmos was down leave their share to the windows they stood
    /// among, as a close does.
    @Test(arguments: permutations([1, 3, 4] as [WindowID]))
    func windowsThatNeverComeBackLeaveNoGap(order: [WindowID]) {
        var before = Session(names: ["a"], monitors: [Desk.main])
        before.place("h[1 v[2 3]:2 4]", on: "a")
        var after = Session(names: ["a"], monitors: [Desk.main])
        after.restore(before.savedLayout())
        for window in order { _ = after.add(window) }
        _ = before.remove(2)
        #expect(after.workspaces["a"]!.sameTree(as: before.workspaces["a"]!), "\(after.workspaces["a"]!.detailed)")
    }

    /// A window Kosmos did not know goes where it goes at any launch, and the saved windows
    /// after it still go back beside the windows they stood among.
    @Test func aNewWindowLeavesTheSavedOnesBesideTheirSiblings() {
        var before = Session(names: ["a"], monitors: [Desk.main])
        before.place("h[1 v[2 3]]", on: "a")
        var after = Session(names: ["a"], monitors: [Desk.main])
        after.restore(before.savedLayout())
        _ = after.add(1)
        _ = after.add(9)
        _ = after.add(3)
        _ = after.add(2)
        #expect(after.workspaces["a"]!.tree == "h[1 v[2 3] 9]")
    }

    /// The built-in display is gone at the restart. Its workspace keeps its windows, hidden,
    /// and the display shows it again when it comes back.
    @Test func aDisplayGoneAtTheRestartGetsItsWorkspaceBackWhenItReturns() {
        let layout = Self.desk().savedLayout()
        var assigned = Desk.home
        for name in ["8", "9", "0"] { assigned[name] = nil }
        var after = Self.restored(layout, monitors: [Desk.main, Desk.left], assigned: assigned)
        #expect(after.shownWorkspaces == ["6", "1"] && after.focusedWorkspace == "1")
        #expect(after.add(80).hide == [80])
        #expect(after.workspace(of: 80) == "8")
        after.reconfigure(names: Desk.names, monitors: [Desk.builtIn, Desk.main, Desk.left], assigned: Desk.home, merge: [:])
        #expect(after.shownWorkspaces == ["6", "1", "8"] && after.focusedWorkspace == "1")
    }

    /// Where the profile disagrees with the saved layout, the profile wins: a display shows
    /// only a workspace it may show, and a window of a workspace the profile leaves out goes
    /// where it would at any launch.
    @Test func theProfileWinsWhereItDisagrees() {
        var before = Session(names: ["a", "b", "c"], monitors: [Desk.main, Desk.left])
        _ = before.add(1, to: "c")
        _ = before.perform(.workspace(.named("c")))
        #expect(before.monitor(of: "c").id == Desk.main.id)
        let layout = before.savedLayout()
        let after = Self.restored(layout, monitors: [Desk.main, Desk.left], assigned: ["c": Desk.left.id],
                                  names: ["a", "b", "c"])
        #expect(after.workspace(shownOn: Desk.main.id) != "c")
        #expect(after.focusedWorkspace == "c" && after.monitor(of: "c").id == Desk.left.id)
        var fewer = Self.restored(layout, monitors: [Desk.main, Desk.left], assigned: [:], names: ["a", "b"])
        _ = fewer.add(1, at: CGPoint(x: -500, y: 500))
        #expect(fewer.workspace(of: 1) == fewer.workspace(shownOn: Desk.left.id))
        #expect(fewer.focusedWorkspace == "a")
    }

    /// A rule's workspace and floating apply to new windows. A saved window is no longer new:
    /// the second Ghostty, which the user moved to hidden 3, lands there though its rule names
    /// 1, and a window the file lacks still follows the rule.
    @Test func aSavedWindowKeepsItsPlaceOverItsRule() {
        var before = Desk.session()
        _ = before.add(10, to: "1")
        _ = before.add(11, to: "1")
        _ = before.perform(.moveNodeToWorkspace(.named("3"), focusFollowsWindow: false, window: 11))
        _ = before.add(12, to: "3")
        _ = before.add(13, to: "3", floating: true)
        #expect(!before.isShown("3"))
        var after = Self.restored(before.savedLayout())
        _ = after.add(10, to: "1")
        #expect(after.add(11, to: "1").hide == [11])
        _ = after.add(12, floating: true)
        _ = after.add(13)
        #expect(after.workspaces["3"]!.tree == "h[11 12]" && after.workspaces["3"]!.floating == [13])
        _ = after.add(14, to: "1")
        #expect(after.workspace(of: 14) == "1")
    }

    /// A hint the tree left behind before the save is still stale after the restart: it holds
    /// no tile, and its window returns by the stale path, as it would have with no restart.
    @Test func aStaleHintStaysStaleAcrossTheRestart() throws {
        var before = Session(names: ["a"], monitors: [Desk.main])
        before.place("h[1 v[2 3]:2]", on: "a")
        var first = Session(names: ["a"], monitors: [Desk.main])
        first.restore(before.savedLayout())
        _ = first.add(1)
        _ = first.add(9)
        let layout = try Self.roundTrip(first.savedLayout())
        #expect(layout.windows.filter(\.stale).map(\.window).sorted() == [2, 3])
        var second = Session(names: ["a"], monitors: [Desk.main])
        second.restore(layout)
        _ = second.add(1)
        _ = second.add(9)
        #expect(second.frames(of: "a")[1]!.width > 900)
        for window in [3, 2] as [WindowID] {
            _ = first.add(window)
            _ = second.add(window)
        }
        #expect(second.workspaces["a"]!.sameTree(as: first.workspaces["a"]!), "\(second.workspaces["a"]!.detailed)")
    }

    /// A tab switch during the hold passes its place to the new tab, and the windows still
    /// pending find it there. A tab that was pending itself takes the place and is pending no
    /// more.
    @Test(arguments: [9, 3] as [WindowID])
    func aTabSwitchDuringTheHoldKeepsThePlaces(new: WindowID) {
        var before = Session(names: ["a"], monitors: [Desk.main])
        before.place("h[1 2 3]", on: "a")
        var after = Session(names: ["a"], monitors: [Desk.main])
        after.restore(before.savedLayout())
        _ = after.add(1)
        let plan = after.replace(1, with: new)
        // A new tab takes the old tab's tile as it was held.
        if new == 9 { #expect(plan?.frames == [9: before.frames(of: "a")[1]!]) }
        for window in [2, 3] as [WindowID] where window != new { _ = after.add(window) }
        #expect(after.workspaces["a"]!.tree == (new == 9 ? "h[9 2 3]" : "h[3 2]"))
        #expect(after.validate().isEmpty && after.savedWorkspace(of: new) == nil)
    }

    /// A profile that leaves a workspace out before its saved windows are back sends them where
    /// they would go at any launch, and listing it again brings none back.
    @Test func pendingWindowsOfAWorkspaceMergedAwayGoAsAtAnyLaunch() {
        var after = Self.restored(Self.desk().savedLayout())
        var assigned = Desk.home
        for name in ["8", "9", "0"] { assigned[name] = nil }
        let fewer = Desk.names.filter { $0 != "8" }
        after.reconfigure(names: fewer, monitors: [Desk.main, Desk.left], assigned: assigned, merge: ["8": "3"])
        #expect(after.savedWorkspace(of: 80) == nil)
        _ = after.add(80, at: CGPoint(x: 500, y: 500))
        #expect(after.workspace(of: 80) == "1")
        after.reconfigure(names: Desk.names, monitors: [Desk.builtIn, Desk.main, Desk.left], assigned: Desk.home, merge: [:])
        #expect(after.workspaces["8"]!.pending.isEmpty && after.workspace(of: 80) == "1")
        #expect(after.validate().isEmpty)
    }

    @Test func theSavedFocusIsAskedForWhenItsWindowComesBack() {
        var before = Session(names: ["a", "b"], monitors: [Desk.main])
        before.place("h[1 2 3]", on: "a")
        before.workspaces["a"]!.focus(2)
        var after = Session(names: ["a", "b"], monitors: [Desk.main])
        after.restore(before.savedLayout())
        #expect(after.savedFocus == 2)
        #expect(after.add(3).focus == nil)
        #expect(after.add(2).focus == .window(2))
        #expect(after.add(1).focus == nil)
        #expect(after.focused == 2 && after.savedFocus == nil)
    }

    /// A key window adopted meanwhile is focused later than the saved focus, so the saved
    /// window does not take the focus back.
    @Test func aWindowFocusedSinceTheLaunchKeepsTheFocus() {
        var before = Session(names: ["a"], monitors: [Desk.main])
        before.place("h[1 2]", on: "a")
        var after = Session(names: ["a"], monitors: [Desk.main])
        after.restore(before.savedLayout())
        _ = after.add(1)
        after.adopt(1)
        #expect(after.add(2).focus == nil)
        #expect(after.focused == 1)
    }

    @Test func windowsNotBackYetAreSavedAgainUntilTheyClose() {
        var before = Session(names: ["a", "b"], monitors: [Desk.main])
        before.place("h[1 2]", on: "a")
        before.place("h[3 4]", on: "b")
        let layout = before.savedLayout()
        var after = Session(names: ["a", "b"], monitors: [Desk.main])
        after.restore(layout)
        _ = after.add(1)
        func byID(_ layout: SavedLayout) -> [WindowID: SavedLayout.Window] {
            Dictionary(uniqueKeysWithValues: layout.windows.map { ($0.window, $0) })
        }
        #expect(byID(after.savedLayout()) == byID(layout))
        _ = after.forgetPending { $0 == 3 }
        #expect(after.savedLayout().windows.map(\.window).sorted() == [1, 2, 4])
    }

    /// A garbled hint would break the tree, as a weight far from the shares Kosmos writes
    /// gives a sibling an infinite share, so its window goes where it would at any launch.
    @Test(arguments: [(5, 0.5, 0.5), (1, .nan, 0.5), (1, 1e300, 0.5), (1, 1e-310, 1), (1, 0.5, 0.6)])
    func aHintKosmosCannotTrustIsLeftOut(index: Int, first: Double, second: Double) {
        var before = Session(names: ["a", "b"], monitors: [Desk.main, Desk.left])
        before.place("h[1 2]", on: "b")
        _ = before.perform(.workspace(.named("b")))
        var layout = before.savedLayout()
        layout.windows[1].levels![0].index = index
        layout.windows[1].levels![0].slots[0].weight = first
        layout.windows[1].levels![0].slots[1].weight = second
        var garbled = Session(names: ["a", "b"], monitors: [Desk.main, Desk.left])
        garbled.restore(layout)
        #expect(garbled.focusedWorkspace == "b" && garbled.workspaces["b"]!.pending.map(\.window) == [1])
        _ = garbled.add(1)
        _ = garbled.add(2)
        #expect(garbled.workspace(of: 2) == "b" && garbled.workspaces["b"]!.tree == "h[1 2]")
        #expect(garbled.workspaces["b"]!.root.children.allSatisfy { $0.weight == 0.5 })
    }

    /// A focus stamp counts only as an order, so no stamp in a file can run the clock over.
    @Test func aSavedStampIsAnOrderOnly() {
        var before = Session(names: ["a", "b"], monitors: [Desk.main, Desk.left])
        before.place("h[1 2]", on: "b")
        _ = before.perform(.workspace(.named("b")))
        var layout = before.savedLayout()
        layout.windows[0].stamp = .max
        var stamped = Session(names: ["a", "b"], monitors: [Desk.main, Desk.left])
        stamped.restore(layout)
        _ = stamped.add(1)
        _ = stamped.add(2)
        stamped.adopt(2)
        #expect(stamped.focused == 2)
    }

    @Test func aWindowClosedAndKeptIsLeftOut() {
        var s = Session(names: ["a"], monitors: [Desk.main])
        s.place("h[1 2]", on: "a")
        _ = s.park([2], because: .closedByApp)
        #expect(s.savedLayout().windows.map(\.window) == [1])
    }
}
