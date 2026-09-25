import CoreGraphics
import Testing
@testable import KosmosCore

private let display = CGRect(x: 0, y: 0, width: 1000, height: 600)

private func gate(_ windows: Set<WindowID> = [10]) -> DragGate {
    var gate = DragGate()
    gate.modifiers = .alt
    gate.windows = windows
    gate.monitors = [Monitor(id: 1, frame: display)]
    return gate
}

@Suite struct DragGateTests {
    private let point = CGPoint(x: 100, y: 100)

    @Test func aPressWithTheModifierOverAManagedWindowTakesTheWholeDrag() {
        var gate = gate()
        let press = gate.pressed(.left, over: 10, flags: .maskAlternate, at: point)
        let grab = DragGate.Grab(button: .left, window: 10, start: point)
        #expect(press == DragGate.Outcome(take: true, began: grab))
        #expect(gate.dragged(to: CGPoint(x: 120, y: 100)) == DragGate.Outcome(take: true, moved: CGPoint(x: 120, y: 100)))
        // The mouse up is taken whatever the modifiers are by then, and ends the drag.
        let up = gate.released(.left, at: CGPoint(x: 150, y: 100))
        #expect(up == DragGate.Outcome(take: true, ended: DragGate.End(grab: grab, point: CGPoint(x: 150, y: 100))))
        #expect(gate.grab == nil && gate.dragged(to: point) == DragGate.Outcome())
        // The right button resizes the same way.
        #expect(gate.pressed(.right, over: 10, flags: .maskAlternate, at: point).began?.button == .right)
        #expect(gate.released(.right, at: point).ended?.grab.button == .right)
    }

    @Test func everyOtherPressPassesUntouched() {
        var gate = gate()
        // Without the modifier, with another one too, and over a window Kosmos does not
        // manage, as the Dock.
        for flags: CGEventFlags in [[], [.maskAlternate, .maskShift], .maskControl] {
            #expect(gate.pressed(.left, over: 10, flags: flags, at: point) == DragGate.Outcome())
        }
        #expect(gate.pressed(.right, over: 99, flags: .maskAlternate, at: point) == DragGate.Outcome(passedOver: 99))
        // Off every display, as the focus path's key record, a left down at 300000, 300000
        // with no mouse up.
        #expect(gate.pressed(.left, over: 10, flags: .maskAlternate, at: CGPoint(x: 300_000, y: 300_000)) == DragGate.Outcome())
        // Their movements and mouse ups pass too.
        #expect(gate.dragged(to: point) == DragGate.Outcome() && gate.released(.left, at: point) == DragGate.Outcome())
        #expect(gate.released(.right, at: point) == DragGate.Outcome())
        // Caps Lock and Fn do not count.
        #expect(gate.pressed(.left, over: 10, flags: [.maskAlternate, .maskAlphaShift, .maskSecondaryFn], at: point).take)
        _ = gate.released(.left, at: point)
        // Off, nothing is taken.
        gate.modifiers = nil
        #expect(gate.pressed(.left, over: 10, flags: .maskAlternate, at: point) == DragGate.Outcome())
    }

    @Test func theOtherButtonPassesDuringTheDrag() {
        var gate = gate()
        _ = gate.pressed(.left, over: 10, flags: .maskAlternate, at: point)
        #expect(gate.pressed(.right, over: 10, flags: .maskAlternate, at: point) == DragGate.Outcome())
        #expect(gate.released(.right, at: point) == DragGate.Outcome())
        // With both buttons down, macOS can name the other one: the movement is the drag's.
        #expect(gate.dragged(to: CGPoint(x: 130, y: 100)).moved == CGPoint(x: 130, y: 100))
        #expect(gate.released(.left, at: point).ended != nil)
    }

    @Test func thePressOfTheFocusPathsKeyRecordLeavesTheDragAlone() {
        var gate = gate()
        let grab = gate.pressed(.left, over: 10, flags: .maskAlternate, at: point).began!
        // The drag focuses a window of an app in the background, and the key record comes as
        // a left down off every display.
        #expect(gate.pressed(.left, over: 10, flags: .maskAlternate, at: CGPoint(x: 300_000, y: 300_000)) == DragGate.Outcome())
        #expect(gate.grab == grab)
        #expect(gate.dragged(to: .zero).take && gate.released(.left, at: .zero).ended?.grab == grab)
    }

    @Test func aPressWithNoMouseUpHeardEndsTheDragWhereThePointerLastMoved() {
        var gate = gate()
        let right = gate.pressed(.right, over: 10, flags: .maskAlternate, at: .zero).began!
        _ = gate.dragged(to: CGPoint(x: 50, y: 0))
        // WindowServer had the tap off as the right button came up. A left press passes to
        // the app, with its mouse up.
        #expect(gate.pressed(.left, over: 10, flags: [], at: point) == DragGate.Outcome())
        #expect(gate.released(.left, at: point) == DragGate.Outcome())
        // The next right press ends the drag and is decided afresh: this one passes, and one
        // with the modifier begins another.
        let press = gate.pressed(.right, over: 10, flags: [], at: point)
        #expect(press == DragGate.Outcome(ended: DragGate.End(grab: right, point: CGPoint(x: 50, y: 0))))
        let first = gate.pressed(.right, over: 10, flags: .maskAlternate, at: .zero).began!
        let again = gate.pressed(.right, over: 10, flags: .maskAlternate, at: point)
        #expect(again.ended == DragGate.End(grab: first, point: .zero) && again.began?.start == point && again.take)
    }

    @Test func aDragWhosePressTimedOutPassesTheRestOfIt() {
        var gate = gate()
        let grab = gate.pressed(.left, over: 10, flags: .maskAlternate, at: point).began!
        // WindowServer gave up on the press and passed it on: the app gets the mouse up too.
        #expect(gate.timedOut() == DragGate.Outcome(ended: DragGate.End(grab: grab, point: point)))
        #expect(gate.dragged(to: .zero) == DragGate.Outcome() && gate.released(.left, at: .zero) == DragGate.Outcome())
        // It gave up on a later event: the drag goes on.
        _ = gate.pressed(.left, over: 10, flags: .maskAlternate, at: point)
        _ = gate.dragged(to: .zero)
        #expect(gate.timedOut() == DragGate.Outcome() && gate.grab != nil)
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
        DragGate.Grab(button: button, window: window, start: start)
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
