import CoreGraphics
import Testing
@testable import KosmosCore

@Suite struct ReconfigureTests {
    @Test func closingTheLidMovesTheBuiltInWorkspacesToTheMainPanel() {
        var s = Desk.session()
        _ = s.add(80, to: "8")
        _ = s.perform(.workspace(.named("8")))
        var assigned = Desk.home
        for name in ["8", "9", "0"] { assigned[name] = 2 }
        s.reconfigure(names: Desk.names, monitors: [Desk.left, Desk.main], assigned: assigned, merge: [:])
        #expect(s.focusedWorkspace == "8" && s.focused == 80)
        #expect(s.shownWorkspaces == ["5", "8"])
        #expect(within(s.frames(of: "8"), Desk.main))
        s.reconfigure(names: Desk.names, monitors: [Desk.builtIn, Desk.left, Desk.main], assigned: Desk.home, merge: [:])
        #expect(s.shownWorkspaces == ["5", "1", "8"])
        #expect(s.focusedWorkspace == "8" && s.focusedDisplay == 3)
    }

    @Test func eachDisplayKeepsItsWorkspaceWhereItMayStay() {
        var s = Desk.session()
        _ = s.perform(.workspace(.named("7")))
        _ = s.perform(.workspace(.named("3")))
        s.reconfigure(names: Desk.names, monitors: [Desk.left, Desk.main, Desk.builtIn], assigned: Desk.home, merge: [:])
        #expect(s.shownWorkspaces == ["7", "3", "8"])
    }

    @Test func aDisplayThatLeavesTakesAFreeFocusedWorkspaceToTheOneFocusedBefore() {
        var s = Session(names: ["a", "b", "c"], monitors: [Desk.main, Desk.left])
        _ = s.perform(.workspace(.named("b")))   // on the left panel
        #expect(s.focusedDisplay == 1)
        s.reconfigure(names: ["a", "b", "c"], monitors: [Desk.main], assigned: [:], merge: [:])
        #expect(s.shownWorkspaces == ["b"])
        #expect(s.focusedWorkspace == "b")
    }

    @Test func aFreeFocusedWorkspaceNoDisplayShowsGoesToTheDisplayFocusedBefore() {
        var s = Session(names: ["a", "b", "c"], monitors: [Desk.main, Desk.left])
        _ = s.perform(.focusMonitor(.direction(.left), wrapAround: false))
        _ = s.perform(.workspace(.named("c")))   // on the left panel, in place of b
        #expect(s.shownWorkspaces == ["c", "a"])
        s.reconfigure(names: ["a", "b"], monitors: [Desk.main, Desk.left], assigned: [:], merge: ["c": "b"])
        // c merged into b, which no display showed, and b takes the left panel, focused
        // before, where the main display would have taken it from a.
        #expect(s.focusedWorkspace == "b" && s.focusedDisplay == 1)
        #expect(s.shownWorkspaces == ["b", "a"])
    }

    @Test func theLaptopProfileMergesTheWorkspacesItLeavesOut() {
        var s = Desk.session()
        _ = s.add(10); _ = s.add(60, to: "6"); _ = s.add(61, to: "6")
        _ = s.add(70, to: "7", floating: true)
        _ = s.add(71, to: "7"); _ = s.park([71])
        _ = s.perform(.workspace(.named("7")))
        let laptop = ["1", "2", "3", "4", "5"]
        s.reconfigure(names: laptop, monitors: [Desk.builtIn], assigned: Dictionary(uniqueKeysWithValues: laptop.map { ($0, 3) }),
                      merge: ["6": "1", "7": "2", "8": "3", "9": "4", "0": "5"])
        #expect(s.names == laptop)
        #expect(s.workspaces["1"]!.tree == "h[10 60 61]")
        #expect(s.workspace(of: 70) == "2" && s.workspaces["2"]!.floating == [70])
        #expect(s.workspace(of: 71) == "2" && s.isParked(71))
        #expect(s.focusedWorkspace == "2" && s.shownWorkspaces == ["2"])
        #expect(within(s.frames(of: "1"), Desk.builtIn))
        // Back at the desk, 61, which the user moved meanwhile, stays where it went.
        _ = s.perform(.moveNodeToWorkspace(.named("3"), focusFollowsWindow: false, window: 61))
        s.reconfigure(names: Desk.names, monitors: [Desk.builtIn, Desk.left, Desk.main], assigned: Desk.home, merge: [:])
        #expect(s.workspaces["6"]!.tree == "h[60]" && s.workspace(of: 61) == "3")
        #expect(s.workspaces["7"]!.floating == [70] && s.isParked(71) && s.workspace(of: 71) == "7")
        #expect(s.workspaces["1"]!.root.windows == [10])
        // Each display shows what it showed before the laptop profile, and the focus stays.
        #expect(s.shownWorkspaces == ["7", "2", "8"])
        _ = s.unpark([71], follow: nil)
        #expect(s.workspaces["7"]!.tree == "h[71]")
    }

    @Test func aMergedWorkspaceComesBackAsItWas() {
        var s = Desk.session()
        _ = s.perform(.workspace(.named("6")))
        _ = s.add(60); _ = s.add(61)
        s.adopt(61)
        _ = s.add(62)
        s.adopt(62)
        _ = s.perform(.joinWith(.left))
        s.adopt(60)
        _ = s.perform(.resize(.width, by: 300))
        s.adopt(62)
        _ = s.add(63, to: "6")
        #expect(s.workspaces["6"]!.tree == "h[60 v[61 62 63]]")
        let frames = s.frames(of: "6")
        let laptop = ["1", "2", "3", "4", "5"]
        s.reconfigure(names: laptop, monitors: [Desk.builtIn], assigned: Dictionary(uniqueKeysWithValues: laptop.map { ($0, 3) }),
                      merge: ["6": "1"])
        #expect(s.workspaces["1"]!.root.windows == [60, 61, 62, 63])
        // Meanwhile 60 minimizes, 61 closes and 63 moves to 3.
        _ = s.park([60])
        _ = s.remove(61)
        _ = s.perform(.moveNodeToWorkspace(.named("3"), focusFollowsWindow: false, window: 63))
        s.reconfigure(names: Desk.names, monitors: [Desk.builtIn, Desk.left, Desk.main], assigned: Desk.home, merge: [:])
        #expect(s.shownWorkspaces == ["6", "1", "8"])
        #expect(s.workspaces["6"]!.tree == "h[62]" && s.isParked(60) && s.workspace(of: 63) == "3")
        #expect(s.workspaces["6"]!.focusedWindow == 62)
        _ = s.unpark([60], follow: nil)
        #expect(s.workspaces["6"]!.tree == "h[60 62]")
        #expect(s.frames(of: "6")[60] == frames[60])
    }

    @Test func windowsReturnToAMergedWorkspaceThatChangedInItsOwnOrder() {
        // A return to a tree that changed depends on the returns before it. Each set of ids
        // would iterate a Set in an order of its own.
        for offset in stride(from: WindowID(0), to: 160, by: 10) {
            let (w1, w2, w3, w4) = (offset + 1, offset + 2, offset + 3, offset + 4)
            let display = Monitor(id: 1, frame: screen, gaps: deskGaps)
            var s = Session(names: ["a", "b"], monitors: [display])
            _ = s.perform(.workspace(.named("b")))
            for window in [w1, w2, w3, w4] { _ = s.add(window) }
            s.adopt(w3)
            _ = s.perform(.resize(.width, by: -1000))
            #expect(s.frames(of: "b")[w3]?.width == 1)
            _ = s.park([w3, w2])
            s.reconfigure(names: ["a"], monitors: [display], assigned: [:], merge: ["b": "a"])
            // Meanwhile 4 closes, and 3 and 2 return.
            _ = s.remove(w4)
            _ = s.unpark([w3, w2], follow: nil)
            s.reconfigure(names: ["a", "b"], monitors: [display], assigned: [:], merge: [:])
            #expect(s.workspaces["b"]!.tree == "h[\(w1) \(w3) \(w2)]", "offset \(offset)")
        }
    }

    @Test(arguments: [false, true])
    func aWindowReturnsToAMergedWorkspaceWithinItsDisplaysGaps(floated: Bool) {
        // The outer gaps leave 3 one point, which 1 would take returning after it, so 1 pairs
        // with 2. Without the gaps 3 has points to spare.
        let display = Monitor(id: 1, frame: screen, gaps: Gaps(inner: 10, outer: Insets(top: 10, left: 300, bottom: 10, right: 300)))
        var s = Session(names: ["a", "b"], monitors: [display])
        _ = s.perform(.workspace(.named("b")))
        _ = s.add(1)
        if floated { _ = s.perform(.layout(.toggleFloating)) } else { _ = s.park([1]) }
        _ = s.add(2); _ = s.add(3)
        s.adopt(2)
        _ = s.perform(.resize(.width, by: 2000))
        s.adopt(3)
        #expect(s.frames(of: "b")[3]?.width == 1)
        s.reconfigure(names: ["a"], monitors: [display], assigned: [:], merge: ["b": "a"])
        // Meanwhile 1 tiles, or returns, in a.
        if floated {
            s.adopt(1)
            _ = s.perform(.layout(.toggleFloating))
        } else {
            _ = s.unpark([1], follow: nil)
        }
        s.reconfigure(names: ["a", "b"], monitors: [display], assigned: [:], merge: [:])
        #expect(s.workspaces["b"]!.tree == "h[v[2 1] 3]")
    }

    @Test func aTabSelectedWhileItsWorkspaceIsMergedReturnsInItsPlace() {
        var s = Desk.session()
        _ = s.add(60, to: "6"); _ = s.add(62, to: "6")
        s.reconfigure(names: ["1", "2", "3", "4", "5"], monitors: [Desk.builtIn], assigned: [:], merge: ["6": "1"])
        _ = s.replace(60, with: 61)
        s.reconfigure(names: Desk.names, monitors: [Desk.builtIn, Desk.left, Desk.main], assigned: Desk.home, merge: [:])
        #expect(s.workspaces["6"]!.tree == "h[61 62]" && s.workspace(of: 61) == "6")
        #expect(s.workspaces["1"]!.root.windows.isEmpty)
    }

    @Test func aMergedWindowThatBecomesTheSelectedTabLeavesItsOwnPlace() {
        var s = Desk.session()
        _ = s.add(60, to: "6"); _ = s.add(61, to: "6")
        s.adopt(61)
        _ = s.add(62, to: "6")
        #expect(s.workspaces["6"]!.tree == "h[60 61 62]")
        s.reconfigure(names: ["1", "2", "3", "4", "5"], monitors: [Desk.builtIn], assigned: [:], merge: ["6": "1"])
        // As after Merge All Windows: 62, placed on its own, is now the tab selected in 60's place.
        _ = s.replace(60, with: 62)
        s.reconfigure(names: Desk.names, monitors: [Desk.builtIn, Desk.left, Desk.main], assigned: Desk.home, merge: [:])
        #expect(s.workspaces["6"]!.tree == "h[62 61]")
    }

    @Test func aFlapMovesTheMergedWindowsBackAtOnce() {
        var s = Desk.session()
        _ = s.add(60, to: "6")
        s.reconfigure(names: ["1", "2", "3", "4", "5"], monitors: [Desk.builtIn], assigned: [:], merge: ["6": "1"])
        #expect(s.workspace(of: 60) == "1")
        s.reconfigure(names: Desk.names, monitors: [Desk.builtIn, Desk.left, Desk.main], assigned: Desk.home, merge: [:])
        #expect(s.workspace(of: 60) == "6")
        #expect(s.workspaces["1"]!.root.windows.isEmpty)
    }

    @Test func aCommandForAWorkspaceTheProfileLeftOutFailsUntilItReturns() {
        var s = Desk.session()
        s.reconfigure(names: ["1", "2", "3", "4", "5"], monitors: [Desk.builtIn], assigned: [:], merge: [:])
        #expect(s.missingWorkspace(in: .workspace(.named("6"))) == "6")
        #expect(s.missingWorkspace(in: .moveNodeToWorkspace(.named("0"), focusFollowsWindow: false)) == "0")
        s.reconfigure(names: Desk.names, monitors: [Desk.builtIn, Desk.left, Desk.main], assigned: Desk.home, merge: [:])
        #expect(s.missingWorkspace(in: .workspace(.named("6"))) == nil)
    }

    @Test func aWorkspaceWithoutAMergeTargetGoesToTheFirst() {
        var s = Session(names: ["a", "b"], display: Desk.main.frame)
        _ = s.add(1, to: "b")
        _ = s.perform(.workspace(.named("b")))
        s.reconfigure(names: ["a"], monitors: [Desk.main], assigned: [:], merge: [:])
        #expect(s.workspace(of: 1) == "a")
        #expect(s.focusedWorkspace == "a" && s.focused == nil)
        #expect(s.perform(.workspaceBackAndForth) == nil)
    }
}
