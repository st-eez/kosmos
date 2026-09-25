import CoreGraphics
import Testing
@testable import KosmosCore

@Suite struct DragTests {
    private let mainCenter = CGPoint(x: 960, y: 540)

    @Test func aWindowDraggedInItsWorkspaceTilesBesideTheWindowUnderThePointer() {
        var s = desk()
        _ = s.add(10); _ = s.add(11)
        s.adopt(11)
        _ = s.add(12)
        #expect(s.workspaces["1"]!.tree == "h[10 11 12]")
        let lift = s.lift(10)!
        #expect(s.workspaces["1"]!.tree == "h[11 12]" && lift.frames[10] == nil && lift.frames[11]!.minX == Desk.main.area.minX + 10)
        #expect(s.lifted == [10] && s.isParked(10))
        // Dropped in the bottom half of 12, which is taller than wide: under it, and the two
        // share its space.
        let tile = lift.frames[12]!
        let plan = s.drop(at: CGPoint(x: tile.midX, y: tile.midY + 100))
        #expect(s.workspaces["1"]!.tree == "h[11 v[12 10]]" && s.lifted.isEmpty)
        #expect(plan.frames[10]!.minY > plan.frames[12]!.minY && plan.frames[10]!.width == tile.width)
        #expect(plan.focus == .window(10) && plan.show.isEmpty && plan.hide.isEmpty)
        #expect(s.focusedWorkspace == "1" && s.focused == 10)
        // 12 is now wider than tall: 11 dropped in its left half goes before it.
        _ = s.lift(11)
        let wide = s.frames(of: "1")[12]!
        _ = s.drop(at: CGPoint(x: wide.minX + 10, y: wide.midY))
        #expect(s.workspaces["1"]!.tree == "v[h[11 12] 10]")
    }

    @Test func thePointerOnAResizeBorderMarksAResize() {
        let frame = CGRect(x: 100, y: 100, width: 800, height: 600)
        // The side and bottom edges, from either side, and above the top edge.
        #expect(TitleBarDrag.onResizeBorder(CGPoint(x: 97, y: 400), of: frame))
        #expect(TitleBarDrag.onResizeBorder(CGPoint(x: 904, y: 400), of: frame))
        #expect(TitleBarDrag.onResizeBorder(CGPoint(x: 500, y: 698), of: frame))
        #expect(TitleBarDrag.onResizeBorder(CGPoint(x: 500, y: 97), of: frame))
        // The title bar, the inside and past the reach.
        #expect(!TitleBarDrag.onResizeBorder(CGPoint(x: 500, y: 110), of: frame))
        #expect(!TitleBarDrag.onResizeBorder(CGPoint(x: 500, y: 400), of: frame))
        #expect(!TitleBarDrag.onResizeBorder(CGPoint(x: 90, y: 400), of: frame))
    }

    @Test func aWindowDroppedOverItsOwnPlaceGoesBackBesideItsNeighbour() {
        var s = desk()
        _ = s.add(10); _ = s.add(11)
        let before = s.frames(of: "1")
        _ = s.lift(11)
        _ = s.drop(at: CGPoint(x: before[11]!.midX, y: before[11]!.midY))
        #expect(s.workspaces["1"]!.tree == "h[10 11]" && s.frames(of: "1") == before)
    }

    @Test func aWindowDroppedInAGapTilesBesideTheClosestWindow() {
        let spaced = Monitor(id: 2, frame: Desk.main.frame, gaps: Gaps(inner: 20, outer: Desk.gaps.outer))
        var s = Session(names: Desk.names, monitors: [spaced])
        _ = s.add(10); _ = s.add(11); _ = s.add(12)
        s.adopt(10)
        _ = s.perform(.resize(.width, by: 300))
        _ = s.lift(12)
        #expect(s.workspaces["1"]!.tree == "h[10 11]")
        // In the gap between the two, level with their centers: 11 is narrower, so its
        // center is closer, and 12 goes under it, as 11 is taller than wide.
        let tiles = s.frames(of: "1")
        let (wide, narrow) = (tiles[10]!, tiles[11]!)
        let gap = CGPoint(x: (wide.maxX + narrow.minX) / 2, y: narrow.midY)
        #expect(!wide.contains(gap) && !narrow.contains(gap) && wide.width > narrow.width)
        _ = s.drop(at: gap)
        #expect(s.workspaces["1"]!.tree == "h[10 v[11 12]]")
    }

    @Test func aWindowDroppedOnAnotherDisplayJoinsItsWorkspace() {
        var s = desk()
        _ = s.add(10); _ = s.add(11); _ = s.add(50, to: "5")
        _ = s.lift(11)
        let plan = s.drop(at: CGPoint(x: -500, y: 540))
        // 50 fills the left panel, wider than tall: 11 dropped in its right half goes after it.
        #expect(s.workspace(of: 11) == "5" && s.workspaces["5"]!.tree == "h[50 11]")
        #expect(s.focusedWorkspace == "5" && s.focused == 11)
        #expect(plan.frames[10] != nil && plan.frames[11] != nil && plan.hide.isEmpty)
        _ = s.lift(11)
        _ = s.drop(at: CGPoint(x: 900, y: 1500))
        #expect(s.workspace(of: 11) == "8" && s.frames(of: "8")[11] == Desk.builtIn.area.insetBy(dx: 10, dy: 10))
    }

    @Test func aDragThatEndsOffEveryDisplayPutsTheWindowBack() {
        var s = desk()
        _ = s.add(10); _ = s.add(11)
        let before = s.frames(of: "1")
        _ = s.lift(10)
        let plan = s.drop(at: CGPoint(x: 5000, y: 5000))
        #expect(s.workspaces["1"]!.tree == "h[10 11]" && plan.frames == before && plan.hide.isEmpty)
    }

    @Test func aSwitchDuringTheDragLeavesTheWindowInTheUsersHand() {
        var s = desk()
        _ = s.add(10); _ = s.add(11)
        _ = s.lift(11)
        #expect(s.perform(.workspace(.named("2")))!.hide == [10])
        // Dropped on the main panel, it joins 2 and asks for the key the switch gave away;
        // off every display, it goes back to 1 and is concealed with it.
        #expect(s.drop(at: mainCenter).focus == .window(11))
        #expect(s.workspace(of: 11) == "2" && s.workspaces["2"]!.tree == "h[11]")
        _ = s.lift(11)
        _ = s.perform(.workspace(.named("3")))
        #expect(s.drop(at: CGPoint(x: -5000, y: 0)).hide == [11] && s.workspace(of: 11) == "2")
    }

    @Test func aHotkeyDuringTheDragDropsTheWindowBeforeItsCommandRuns() {
        var s = desk()
        _ = s.add(10); _ = s.add(11)
        _ = s.lift(11)
        // The controller drops 11 before the hotkey's switch runs, and the switch conceals it
        // with 10.
        let tile = s.frames(of: "1")[10]!
        #expect(s.drop(at: CGPoint(x: tile.maxX - 100, y: tile.midY)).focus == .window(11))
        #expect(s.lifted.isEmpty && s.workspaces["1"]!.tree == "h[10 11]")
        let plan = s.perform(.workspace(.named("2")))!
        #expect(Set(plan.hide) == [10, 11] && s.focusedWorkspace == "2" && s.focused == nil)
        #expect(s.perform(.workspace(.named("1")))!.focus == .window(11))
    }

    @Test func aWindowThatLeavesOrParksDuringTheDragIsNotDropped() {
        var s = desk()
        _ = s.add(10); _ = s.add(11); _ = s.add(12)
        _ = s.lift(11)
        _ = s.remove(11)
        _ = s.lift(12)
        _ = s.park([12])   // minimized, or closed and kept by its app
        #expect(s.lifted.isEmpty && s.isParked(12))
        #expect(s.drop(at: mainCenter).isEmpty)
        _ = s.unpark([12], follow: nil)
        #expect(s.workspaces["1"]!.root.windows.sorted() == [10, 12])
        // A lock or a display change during the drag puts the window back.
        _ = s.lift(10)
        s.reconfigure(names: Desk.names, monitors: [Desk.builtIn, Desk.main, Desk.left], assigned: Desk.home, merge: [:])
        #expect(s.lifted.isEmpty && s.workspaces["1"]!.root.windows.sorted() == [10, 12])
    }
}
