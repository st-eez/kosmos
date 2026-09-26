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
    static let server = SavedLayout.Process(pid: 400, start: 1_790_000_000_000_000)

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
        s.restore(layout, windowServer: server)
        return s
    }

    @Test(arguments: 0..<24 as Range<UInt64>)
    func aRestartPutsEveryWindowBackInAnyOrder(seed: UInt64) throws {
        let before = Self.desk()
        var after = Self.restored(try Self.roundTrip(before.savedLayout(windowServer: Self.server)))
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
        after.restore(try Self.roundTrip(before.savedLayout(windowServer: Self.server)), windowServer: Self.server)
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
        after.restore(try Self.roundTrip(before.savedLayout(windowServer: Self.server)), windowServer: Self.server)
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
        after.restore(before.savedLayout(windowServer: Self.server), windowServer: Self.server)
        for window in order.dropLast() {
            #expect(after.add(window).frames == tiles.filter { after.workspace(of: $0.key) != nil })
        }
        let closed = order.last!
        let plan = after.forgetPending { $0 == closed }
        _ = before.remove(closed)
        #expect(plan.frames == before.frames(of: "a"))
    }

    /// A window Kosmos did not know changes the tree, and the tiles held for the saved windows
    /// go to the windows on screen.
    @Test func aNewWindowEndsTheHold() {
        var before = Session(names: ["a"], monitors: [Desk.main])
        before.place("h[1 2 3]", on: "a")
        var after = Session(names: ["a"], monitors: [Desk.main])
        after.restore(before.savedLayout(windowServer: Self.server), windowServer: Self.server)
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
        after.restore(before.savedLayout(windowServer: Self.server), windowServer: Self.server)
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
        after.restore(before.savedLayout(windowServer: Self.server), windowServer: Self.server)
        _ = after.add(1)
        _ = after.add(9)
        _ = after.add(3)
        _ = after.add(2)
        #expect(after.workspaces["a"]!.tree == "h[1 v[2 3] 9]")
    }

    /// The built-in display is gone at the restart. Its workspace keeps its windows, hidden,
    /// and the display shows it again when it comes back.
    @Test func aDisplayGoneAtTheRestartGetsItsWorkspaceBackWhenItReturns() {
        let layout = Self.desk().savedLayout(windowServer: Self.server)
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
        let layout = before.savedLayout(windowServer: Self.server)
        var after = Self.restored(layout, monitors: [Desk.main, Desk.left], assigned: ["c": Desk.left.id],
                                  names: ["a", "b", "c"])
        #expect(after.workspace(shownOn: Desk.main.id) != "c")
        #expect(after.focusedWorkspace == "c" && after.monitor(of: "c").id == Desk.left.id)
        var fewer = Self.restored(layout, monitors: [Desk.main, Desk.left], assigned: [:], names: ["a", "b"])
        _ = fewer.add(1, at: CGPoint(x: -500, y: 500))
        #expect(fewer.workspace(of: 1) == fewer.workspace(shownOn: Desk.left.id))
        #expect(fewer.focusedWorkspace == "a")
    }

    /// A rule's workspace and floating apply to new windows. A saved window is no longer new,
    /// as the second Ghostty the user moved from 1, its rule's workspace, to 8.
    @Test func aSavedWindowKeepsItsPlaceOverItsRule() {
        var before = Desk.session()
        _ = before.add(10, to: "8")
        _ = before.add(11, to: "8")
        _ = before.add(12, to: "8", floating: true)
        var after = Self.restored(before.savedLayout(windowServer: Self.server))
        _ = after.add(10, to: "1")
        _ = after.add(11, floating: true)
        _ = after.add(12)
        #expect(after.workspaces["8"]!.tree == "h[10 11]" && after.workspaces["8"]!.floating == [12])
    }

    @Test func theSavedFocusIsAskedForWhenItsWindowComesBack() {
        var before = Session(names: ["a", "b"], monitors: [Desk.main])
        before.place("h[1 2 3]", on: "a")
        before.workspaces["a"]!.focus(2)
        var after = Session(names: ["a", "b"], monitors: [Desk.main])
        after.restore(before.savedLayout(windowServer: Self.server), windowServer: Self.server)
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
        after.restore(before.savedLayout(windowServer: Self.server), windowServer: Self.server)
        _ = after.add(1)
        after.adopt(1)
        #expect(after.add(2).focus == nil)
        #expect(after.focused == 1)
    }

    @Test func windowsNotBackYetAreSavedAgainUntilTheyClose() {
        var before = Session(names: ["a", "b"], monitors: [Desk.main])
        before.place("h[1 2]", on: "a")
        before.place("h[3 4]", on: "b")
        let layout = before.savedLayout(windowServer: Self.server)
        var after = Session(names: ["a", "b"], monitors: [Desk.main])
        after.restore(layout, windowServer: Self.server)
        _ = after.add(1)
        func byID(_ layout: SavedLayout) -> [WindowID: SavedLayout.Window] {
            Dictionary(uniqueKeysWithValues: layout.windows.map { ($0.id, $0) })
        }
        #expect(byID(after.savedLayout(windowServer: Self.server)) == byID(layout))
        _ = after.forgetPending { $0 == 3 }
        #expect(after.savedLayout(windowServer: Self.server).windows.map(\.id).sorted() == [1, 2, 4])
    }

    /// Window ids from another WindowServer name other windows, and a garbled place would
    /// break the tree, so each goes where it would at any launch. A focus stamp counts only
    /// as an order, so no stamp in a file can run the clock over.
    @Test func aLayoutKosmosCannotTrustChangesNothing() {
        var before = Session(names: ["a", "b"], monitors: [Desk.main, Desk.left])
        before.place("h[1 2]", on: "b")
        _ = before.perform(.workspace(.named("b")))
        var layout = before.savedLayout(windowServer: Self.server)
        var other = Session(names: ["a", "b"], monitors: [Desk.main, Desk.left])
        other.restore(layout, windowServer: SavedLayout.Process(pid: Self.server.pid, start: Self.server.start + 1))
        #expect(other.focusedWorkspace == "a")
        _ = other.add(1)
        #expect(other.workspace(of: 1) == "a")

        layout.windows[0].place![0].index = 5
        layout.windows[1].place![0].slots[0].weight = .nan
        var garbled = Session(names: ["a", "b"], monitors: [Desk.main, Desk.left])
        garbled.restore(layout, windowServer: Self.server)
        #expect(garbled.focusedWorkspace == "b" && garbled.workspaces["b"]!.pending.isEmpty)
        _ = garbled.add(1)
        _ = garbled.add(2)
        #expect(garbled.workspace(of: 1) == "b" && garbled.workspaces["b"]!.tree == "h[1 2]")

        // A focus stamp is only an order.
        layout = before.savedLayout(windowServer: Self.server)
        layout.windows[0].focus = .max
        var stamped = Session(names: ["a", "b"], monitors: [Desk.main, Desk.left])
        stamped.restore(layout, windowServer: Self.server)
        _ = stamped.add(1)
        _ = stamped.add(2)
        stamped.adopt(2)
        #expect(stamped.focused == 2)
    }

    @Test func aWindowClosedAndKeptIsLeftOut() {
        var s = Session(names: ["a"], monitors: [Desk.main])
        s.place("h[1 2]", on: "a")
        _ = s.park([2], because: .closedByApp)
        #expect(s.savedLayout(windowServer: Self.server).windows.map(\.id) == [1])
    }
}
