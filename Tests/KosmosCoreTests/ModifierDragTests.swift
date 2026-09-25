import CoreGraphics
import Testing
@testable import KosmosCore

private let display = CGRect(x: 0, y: 0, width: 1000, height: 600)

private func gate(_ windows: Set<WindowID> = [10]) -> DragGate {
    var gate = DragGate()
    gate.modifiers = .alt
    gate.windows = windows
    return gate
}

@Suite struct DragGateTests {
    @Test func aPressWithTheModifierOverAManagedWindowTakesTheWholeDrag() {
        var gate = gate()
        let press = gate.pressed(.left, over: 10, flags: .maskAlternate, at: CGPoint(x: 100, y: 100))
        let grab = DragGate.Grab(number: 1, button: .left, window: 10, start: CGPoint(x: 100, y: 100))
        #expect(press == DragGate.Outcome(take: true, began: grab))
        // The main actor hears of the first movement, and takes only the latest.
        #expect(gate.dragged(.left, to: CGPoint(x: 120, y: 100)) == DragGate.Outcome(take: true, moved: 1))
        #expect(gate.dragged(.left, to: CGPoint(x: 130, y: 100)) == DragGate.Outcome(take: true))
        #expect(gate.takeMovement(of: 1) == CGPoint(x: 130, y: 100) && gate.takeMovement(of: 1) == nil)
        #expect(gate.dragged(.left, to: CGPoint(x: 140, y: 100)).moved == 1)
        // The mouse up is taken whatever the modifiers are by then, and ends the drag.
        let up = gate.released(.left, at: CGPoint(x: 150, y: 100))
        #expect(up == DragGate.Outcome(take: true, ended: DragGate.End(grab: grab, point: CGPoint(x: 150, y: 100))))
        #expect(gate.grab == nil && gate.takeMovement(of: 1) == nil)
        // The right button resizes the same way.
        #expect(gate.pressed(.right, over: 10, flags: .maskAlternate, at: .zero).began?.button == .right)
        #expect(gate.released(.right, at: .zero).ended?.grab.number == 2)
    }

    @Test func everyOtherPressPassesUntouched() {
        var gate = gate()
        let point = CGPoint(x: 100, y: 100)
        // Without the modifier, with another one too, and over a window Kosmos does not
        // manage, as the Dock.
        for flags: CGEventFlags in [[], [.maskAlternate, .maskShift], .maskControl] {
            #expect(gate.pressed(.left, over: 10, flags: flags, at: point) == DragGate.Outcome())
        }
        #expect(gate.pressed(.right, over: 99, flags: .maskAlternate, at: point) == DragGate.Outcome(passedOver: 99))
        // Their movements and mouse ups pass too.
        #expect(gate.dragged(.left, to: point) == DragGate.Outcome() && gate.released(.left, at: point) == DragGate.Outcome())
        #expect(gate.released(.right, at: point) == DragGate.Outcome())
        // Caps Lock and Fn do not count.
        #expect(gate.pressed(.left, over: 10, flags: [.maskAlternate, .maskAlphaShift, .maskSecondaryFn], at: point).take)
        _ = gate.released(.left, at: point)
        // Off, nothing is taken.
        gate.modifiers = nil
        #expect(gate.pressed(.left, over: 10, flags: .maskAlternate, at: point) == DragGate.Outcome())
    }

    @Test func aPressOfTheOtherButtonDuringTheDragIsTakenWithItsMouseUp() {
        var gate = gate()
        let point = CGPoint(x: 100, y: 100)
        _ = gate.pressed(.left, over: 10, flags: .maskAlternate, at: point)
        #expect(gate.pressed(.right, over: 0, flags: [], at: point) == DragGate.Outcome(take: true))
        #expect(gate.released(.right, at: point) == DragGate.Outcome(take: true))
        _ = gate.pressed(.right, over: 0, flags: [], at: point)
        #expect(gate.released(.left, at: point).ended != nil)
        // Held past the drag's end, the other button's movements and mouse up are still taken.
        #expect(gate.dragged(.right, to: point) == DragGate.Outcome(take: true))
        #expect(gate.released(.right, at: point) == DragGate.Outcome(take: true))
        #expect(gate.released(.right, at: point) == DragGate.Outcome())
    }

    @Test func aPressWithNoMouseUpHeardEndsTheDragWhereThePointerLastMoved() {
        var gate = gate()
        let first = gate.pressed(.left, over: 10, flags: .maskAlternate, at: .zero).began!
        _ = gate.dragged(.left, to: CGPoint(x: 50, y: 0))
        // WindowServer had the tap off as the button came up. The next press ends the drag,
        // and is decided afresh: this one passes, and one with the modifier begins another.
        let press = gate.pressed(.left, over: 10, flags: [], at: CGPoint(x: 300, y: 300))
        #expect(press == DragGate.Outcome(ended: DragGate.End(grab: first, point: CGPoint(x: 50, y: 0))))
        #expect(gate.takeMovement(of: 1) == nil)
        _ = gate.pressed(.left, over: 10, flags: .maskAlternate, at: .zero)
        let again = gate.pressed(.left, over: 10, flags: .maskAlternate, at: CGPoint(x: 5, y: 5))
        #expect(again.ended?.grab.number == 2 && again.ended?.point == .zero && again.began?.number == 3 && again.take)
    }

    @Test func aLateMovementOfAnEndedDragIsNotTaken() {
        var gate = gate()
        _ = gate.pressed(.left, over: 10, flags: .maskAlternate, at: .zero)
        #expect(gate.dragged(.left, to: CGPoint(x: 20, y: 0)).moved == 1)
        _ = gate.released(.left, at: CGPoint(x: 30, y: 0))
        _ = gate.pressed(.left, over: 10, flags: .maskAlternate, at: .zero)
        #expect(gate.dragged(.left, to: CGPoint(x: 40, y: 0)).moved == 2)
        // The first drag's movement reaches the main actor after the second drag moved.
        #expect(gate.takeMovement(of: 1) == nil)
        #expect(gate.takeMovement(of: 2) == CGPoint(x: 40, y: 0))
    }
}

@Suite struct ModifierDragTests {
    /// Tiles 10, 11 and 12 side by side on `display`, with 11 focused.
    private func row() -> Session {
        var s = Session(names: ["1", "2"], display: display)
        _ = s.add(10); _ = s.add(11)
        s.adopt(11)
        _ = s.add(12)
        #expect(s.workspaces["1"]!.tree == "h[10 11 12]")
        return s
    }

    private func grab(_ window: WindowID, at start: CGPoint, _ button: DragButton = .right) -> DragGate.Grab {
        DragGate.Grab(number: 1, button: button, window: window, start: start)
    }

    @Test func nothingMovesUntilThePointerGoesPastTheLiftDistance() throws {
        let s = row()
        let tile = s.frames(of: "1")[11]!
        var drag = try #require(s.beginDrag(grab(11, at: CGPoint(x: tile.midX, y: tile.midY), .left), frame: tile))
        #expect(drag.delta(to: CGPoint(x: tile.midX + 6, y: tile.midY + 8)) == nil)
        #expect(drag.delta(to: CGPoint(x: tile.midX + 7, y: tile.midY + 8)) == CGSize(width: 7, height: 8))
        // Past it once, the window follows the pointer back too.
        #expect(drag.delta(to: CGPoint(x: tile.midX + 1.4, y: tile.midY)) == CGSize(width: 1, height: 0))
        #expect(drag.moved(by: CGSize(width: 1, height: 0)) == tile.offsetBy(dx: 1, dy: 0))
    }

    @Test func aTileResizesByTheEdgeOnTheSideOfThePress() throws {
        var s = row()
        let before = s.frames(of: "1")
        let tile = before[11]!
        // In the top right quarter: the right edge. No tile is above or below it.
        let drag = try #require(s.beginDrag(grab(11, at: CGPoint(x: tile.maxX - 10, y: tile.minY + 10)), frame: tile))
        #expect(drag.edges == [.right] && !drag.floating)
        let plan = s.dragEdges(drag, by: CGSize(width: 60, height: 30))
        var frames = try #require(plan).frames
        #expect(frames[11]!.minX == tile.minX && frames[11]!.maxX == tile.maxX + 60 && frames[11]!.height == tile.height)
        #expect(frames[10] == before[10] && frames[12]!.maxX == before[12]!.maxX)
        // The edge follows the pointer back past where it started.
        let back = s.dragEdges(drag, by: CGSize(width: -30, height: 0))
        frames = try #require(back).frames
        #expect(frames[11]!.maxX == tile.maxX - 30 && frames[11]!.minX == tile.minX)
        let still = s.dragEdges(drag, by: CGSize(width: -30, height: 0))
        #expect(still == nil)
    }

    @Test func aTileWithNoNeighbourOnThatSideMovesItsOtherEdge() throws {
        var s = row()
        let before = s.frames(of: "1")
        let tile = before[12]!
        let drag = try #require(s.beginDrag(grab(12, at: CGPoint(x: tile.maxX - 10, y: tile.maxY - 10)), frame: tile))
        #expect(drag.edges == [.left])
        let plan = s.dragEdges(drag, by: CGSize(width: -50, height: 0))
        let frames = try #require(plan).frames
        #expect(frames[12]!.minX == tile.minX - 50 && frames[12]!.maxX == tile.maxX)
        #expect(frames[11]!.minX == before[11]!.minX && frames[10] == before[10])
        // A lone tile has no edge to move.
        var lone = Session(names: ["1"], display: display)
        _ = lone.add(20)
        let whole = lone.frames(of: "1")[20]!
        #expect(lone.beginDrag(grab(20, at: .zero), frame: whole)!.edges.isEmpty)
    }

    @Test func aTileInAColumnResizesOnBothAxes() throws {
        var s = row()
        s.adopt(12)
        _ = s.perform(.joinWith(.left))
        #expect(s.workspaces["1"]!.tree == "h[10 v[11 12]]")
        let before = s.frames(of: "1")
        let tile = before[12]!
        let drag = try #require(s.beginDrag(grab(12, at: CGPoint(x: tile.minX + 10, y: tile.minY + 10)), frame: tile))
        #expect(drag.edges == [.left, .up])
        let plan = s.dragEdges(drag, by: CGSize(width: -40, height: -30))
        let frames = try #require(plan).frames
        #expect(frames[12]!.minX == tile.minX - 40 && frames[12]!.minY == tile.minY - 30 && frames[12]!.maxY == tile.maxY)
        #expect(frames[11]!.minX == tile.minX - 40 && frames[11]!.maxY == before[11]!.maxY - 30)
        #expect(frames[10]!.maxX == before[10]!.maxX - 40)
    }

    @Test func anEdgeStoppedAtALimitFollowsThePointerBack() throws {
        var s = Session(names: ["1"], display: display)
        _ = s.add(10); _ = s.add(11)
        let tile = s.frames(of: "1")[10]!
        let drag = try #require(s.beginDrag(grab(10, at: CGPoint(x: tile.maxX - 1, y: tile.midY)), frame: tile))
        let far = s.dragEdges(drag, by: CGSize(width: 2000, height: 0))
        #expect(far?.frames[11]?.width == 1)
        // The edge goes where the pointer is, not 1900 pt left of where the limit stopped it.
        let back = s.dragEdges(drag, by: CGSize(width: 100, height: 0))
        #expect(back?.frames[10]?.maxX == tile.maxX + 100)
    }

    @Test func onlyATiledOrFloatingWindowOfAShownWorkspaceIsDragged() {
        var s = row()
        _ = s.add(20, to: "2")
        _ = s.add(21)
        _ = s.park([21])
        for window: WindowID in [20, 21, 99] {
            #expect(s.beginDrag(grab(window, at: .zero), frame: display) == nil)
        }
        // A workspace in fullscreen resizes nothing: the fullscreen window covers the tiles.
        let tile = s.frames(of: "1")[11]!
        let drag = s.beginDrag(grab(11, at: CGPoint(x: tile.maxX - 1, y: tile.midY)), frame: tile)!
        _ = s.perform(.fullscreen)
        let plan = s.dragEdges(drag, by: CGSize(width: 50, height: 0))
        #expect(plan == nil)
    }

    @Test func aFloatingWindowResizesFromTheCornerNearestThePress() throws {
        var s = Session(names: ["1"], display: display)
        _ = s.add(20)
        _ = s.float(20)
        let frame = CGRect(x: 100, y: 100, width: 400, height: 300)
        let topLeft = try #require(s.beginDrag(grab(20, at: CGPoint(x: 150, y: 150)), frame: frame))
        #expect(topLeft.floating && topLeft.edges == [.left, .up])
        #expect(s.resized(topLeft, by: CGSize(width: 50, height: -20)) == CGRect(x: 150, y: 80, width: 350, height: 320))
        // Past the other edges, the window keeps 20 pt, and its far edges stay.
        #expect(s.resized(topLeft, by: CGSize(width: 1000, height: 1000)) == CGRect(x: 480, y: 380, width: 20, height: 20))
        let bottomRight = try #require(s.beginDrag(grab(20, at: CGPoint(x: 300, y: 250)), frame: frame))
        #expect(bottomRight.edges == [.right, .down])
        #expect(s.resized(bottomRight, by: CGSize(width: 30, height: -500)) == CGRect(x: 100, y: 100, width: 430, height: 20))
        // A minimum the window showed holds too.
        _ = s.setMinimum(20, CGSize(width: 200, height: 0))
        #expect(s.resized(bottomRight, by: CGSize(width: -1000, height: 0)).width == 200)
    }
}
