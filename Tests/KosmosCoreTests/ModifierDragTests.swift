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

private func held(_ button: DragButton) -> DragGate.ButtonState { DragGate.ButtonState(down: true, presses: 1) }

extension DragGate {
    fileprivate mutating func pressed(_ button: DragButton, over window: WindowID, flags: CGEventFlags, at point: CGPoint,
                                      hid: (DragButton) -> ButtonState = held) -> Outcome {
        pressed(button, number: 1, over: window, flags: flags, at: point, hid: hid)
    }

    fileprivate mutating func released(_ button: DragButton, at point: CGPoint) -> Outcome {
        released(button, number: 1, at: point)
    }
}

@Suite struct DragGateTests {
    private let point = CGPoint(x: 100, y: 100)

    @Test func aPressWithTheModifierOverAManagedWindowTakesTheWholeDrag() {
        var gate = gate()
        let press = gate.pressed(.left, over: 10, flags: .maskAlternate, at: point)
        let grab = DragGate.Grab(button: .left, window: 10, start: point)
        #expect(press == DragGate.Outcome(take: true, began: grab))
        #expect(gate.dragged(to: CGPoint(x: 120, y: 100)) == DragGate.Outcome(take: true, moved: CGPoint(x: 120, y: 100)))
        let up = gate.released(.left, at: CGPoint(x: 150, y: 100))
        #expect(up == DragGate.Outcome(take: true, ended: DragGate.End(grab: grab, point: CGPoint(x: 150, y: 100))))
        #expect(gate.grab == nil && gate.dragged(to: point) == DragGate.Outcome())
        #expect(gate.pressed(.right, over: 10, flags: .maskAlternate, at: point).began?.button == .right)
        #expect(gate.released(.right, at: point).ended?.grab.button == .right)
    }

    @Test func everyOtherPressPassesUntouched() {
        var gate = gate()
        for flags: CGEventFlags in [[], [.maskAlternate, .maskShift], .maskControl] {
            #expect(gate.pressed(.left, over: 10, flags: flags, at: point) == DragGate.Outcome())
        }
        #expect(gate.pressed(.right, over: 99, flags: .maskAlternate, at: point) == DragGate.Outcome(passedOver: 99))
        // The focus path's key record: a left down off every display.
        #expect(gate.pressed(.left, over: 10, flags: .maskAlternate, at: CGPoint(x: 300_000, y: 300_000)) == DragGate.Outcome())
        #expect(gate.dragged(to: point) == DragGate.Outcome() && gate.released(.left, at: point) == DragGate.Outcome())
        #expect(gate.released(.right, at: point) == DragGate.Outcome())
        #expect(gate.pressed(.left, over: 10, flags: [.maskAlternate, .maskAlphaShift, .maskSecondaryFn], at: point).take)
        _ = gate.released(.left, at: point)
        gate.modifiers = nil
        #expect(gate.pressed(.left, over: 10, flags: .maskAlternate, at: point) == DragGate.Outcome())
    }

    @Test func theOtherButtonPassesDuringTheDrag() {
        var gate = gate()
        _ = gate.pressed(.left, over: 10, flags: .maskAlternate, at: point)
        #expect(gate.pressed(.right, over: 10, flags: .maskAlternate, at: point) == DragGate.Outcome())
        #expect(gate.released(.right, at: point) == DragGate.Outcome())
        // With both buttons down, macOS can name the other one.
        #expect(gate.dragged(to: CGPoint(x: 130, y: 100)).moved == CGPoint(x: 130, y: 100))
        #expect(gate.released(.left, at: point).ended != nil)
    }

    @Test func thePressOfTheFocusPathsKeyRecordLeavesTheDragAlone() {
        var gate = gate()
        let grab = gate.pressed(.left, over: 10, flags: .maskAlternate, at: point).began!
        // Focusing a background app's window posts the key record, a left down off every
        // display.
        #expect(gate.pressed(.left, over: 10, flags: .maskAlternate, at: CGPoint(x: 300_000, y: 300_000)) == DragGate.Outcome())
        #expect(gate.grab == grab)
        #expect(gate.dragged(to: .zero).take && gate.released(.left, at: .zero).ended?.grab == grab)
    }

    @Test func aPressOfTheDragsButtonEndsTheDragWhereThePointerLastMoved() {
        var gate = gate()
        let right = gate.pressed(.right, over: 10, flags: .maskAlternate, at: .zero).began!
        _ = gate.dragged(to: CGPoint(x: 50, y: 0))
        // Its mouse up went unheard.
        let press = gate.pressed(.right, over: 10, flags: [], at: point)
        #expect(press == DragGate.Outcome(ended: DragGate.End(grab: right, point: CGPoint(x: 50, y: 0))))
        let first = gate.pressed(.right, over: 10, flags: .maskAlternate, at: .zero).began!
        let again = gate.pressed(.right, over: 10, flags: .maskAlternate, at: point)
        #expect(again.ended == DragGate.End(grab: first, point: .zero) && again.began?.start == point && again.take)
    }

    @Test func aDragEndsOnceHIDReadsItsPressOver() {
        var gate = gate()
        let grab = gate.pressed(.left, over: 10, flags: .maskAlternate, at: point).began!
        _ = gate.dragged(to: CGPoint(x: 50, y: 0))
        #expect(gate.endIfReleased(hid: held, at: .zero) == DragGate.Outcome() && gate.grab == grab)
        // Its mouse up passed while WindowServer had the tap off.
        let up = { (_: DragButton) in DragGate.ButtonState(down: false, presses: 1) }
        #expect(gate.endIfReleased(hid: up, at: nil) == DragGate.Outcome(ended: DragGate.End(grab: grab, point: CGPoint(x: 50, y: 0))))
        // The button came up and went down again while the tap was off.
        let next = gate.pressed(.left, over: 10, flags: .maskAlternate, at: point).began!
        let again = { (_: DragButton) in DragGate.ButtonState(down: true, presses: 2) }
        #expect(gate.endIfReleased(hid: again, at: .zero) == DragGate.Outcome(ended: DragGate.End(grab: next, point: .zero)))
        #expect(gate.dragged(to: point) == DragGate.Outcome() && gate.released(.left, number: 2, at: point) == DragGate.Outcome())
    }

    @Test func theMouseUpOfADragHIDEndedFirstIsTaken() {
        var gate = gate()
        let grab = gate.pressed(.left, number: 7, over: 10, flags: .maskAlternate, at: point, hid: held).began!
        // At a hotkey HID reads the button up before the tap sees the mouse up, and the
        // hotkey's focus posts the key record meanwhile.
        let up = { (_: DragButton) in DragGate.ButtonState(down: false, presses: 1) }
        #expect(gate.endIfReleased(hid: up, at: point) == DragGate.Outcome(ended: DragGate.End(grab: grab, point: point)))
        _ = gate.pressed(.left, number: 0, over: 10, flags: [], at: CGPoint(x: 300_000, y: 300_000), hid: up)
        #expect(gate.released(.right, number: 7, at: point) == DragGate.Outcome())
        #expect(gate.released(.left, number: 7, at: point) == DragGate.Outcome(take: true))
        #expect(gate.released(.left, number: 7, at: point) == DragGate.Outcome())
        // Its mouse up passed while WindowServer had the tap off.
        _ = gate.pressed(.left, number: 8, over: 10, flags: .maskAlternate, at: point, hid: held)
        _ = gate.endIfReleased(hid: up, at: point)
        #expect(gate.pressed(.left, number: 9, over: 10, flags: [], at: point, hid: up) == DragGate.Outcome())
        #expect(gate.released(.left, number: 8, at: point) == DragGate.Outcome())
    }

    @Test func aMouseUpOfAnotherPressEndsTheDragAndPasses() {
        var gate = gate()
        let grab = gate.pressed(.left, number: 7, over: 10, flags: .maskAlternate, at: point, hid: held).began!
        // Its mouse up and the next press passed while WindowServer had the tap off, and HID
        // counted that press before the tap saw the drag's.
        #expect(gate.released(.left, number: 8, at: point) == DragGate.Outcome(ended: DragGate.End(grab: grab, point: point)))
        #expect(gate.grab == nil && gate.released(.left, number: 7, at: point) == DragGate.Outcome())
    }

    @Test func theOtherButtonsPressEndsADragWhosePressIsOver() {
        var gate = gate()
        let right = gate.pressed(.right, over: 10, flags: .maskAlternate, at: .zero).began!
        // The right button came up while WindowServer had the tap off.
        let rightUp = { (button: DragButton) in DragGate.ButtonState(down: button == .left, presses: 1) }
        let press = gate.pressed(.left, over: 10, flags: [], at: point, hid: rightUp)
        #expect(press == DragGate.Outcome(ended: DragGate.End(grab: right, point: point)))
        #expect(gate.released(.left, at: point) == DragGate.Outcome())
        _ = gate.pressed(.right, over: 10, flags: .maskAlternate, at: .zero)
        let left = gate.pressed(.left, over: 10, flags: .maskAlternate, at: point, hid: rightUp)
        #expect(left.ended?.grab.button == .right && left.began?.button == .left && left.take)
    }

    @Test func aDragWhosePressTimedOutPassesTheRestOfIt() {
        var gate = gate()
        let grab = gate.pressed(.left, over: 10, flags: .maskAlternate, at: point).began!
        // WindowServer gave up on the press and passed it on.
        #expect(gate.timedOut() == DragGate.Outcome(ended: DragGate.End(grab: grab, point: point)))
        #expect(gate.dragged(to: .zero) == DragGate.Outcome() && gate.released(.left, at: .zero) == DragGate.Outcome())
        // It gave up on a later event.
        _ = gate.pressed(.left, over: 10, flags: .maskAlternate, at: point)
        _ = gate.dragged(to: .zero)
        #expect(gate.timedOut() == DragGate.Outcome() && gate.grab != nil)
    }
}

@Suite struct ModifierDragTests {
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
        #expect(drag.delta(to: CGPoint(x: tile.midX + 1.4, y: tile.midY)) == CGSize(width: 1, height: 0))
        #expect(drag.moved(by: CGSize(width: 1, height: 0)) == tile.offsetBy(dx: 1, dy: 0))
    }

    @Test func aTileResizesByTheEdgeOnTheSideOfThePress() throws {
        var s = row()
        let before = s.frames(of: "1")
        let tile = before[11]!
        let drag = try #require(s.beginDrag(grab(11, at: CGPoint(x: tile.maxX - 10, y: tile.minY + 10)), frame: tile))
        #expect(drag.edges == [.right] && !drag.floating)
        let plan = s.dragEdges(drag, by: CGSize(width: 60, height: 30))
        var frames = try #require(plan).frames
        #expect(frames[11]!.minX == tile.minX && frames[11]!.maxX == tile.maxX + 60 && frames[11]!.height == tile.height)
        #expect(frames[10] == before[10] && frames[12]!.maxX == before[12]!.maxX)
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
        #expect(far?.frames[11]?.width == 50)
        let back = s.dragEdges(drag, by: CGSize(width: 100, height: 0))
        #expect(back?.frames[10]?.maxX == tile.maxX + 100)
    }

    @Test func onlyATiledOrFloatingWindowOfAShownWorkspaceIsDragged() {
        var s = row()
        _ = s.add(20, to: "2")
        _ = s.add(21)
        _ = s.park([21], because: .minimized)
        for window: WindowID in [20, 21, 99] {
            #expect(s.beginDrag(grab(window, at: .zero), frame: display) == nil)
        }
        // The fullscreen window covers the tiles, so they resize nothing.
        let tile = s.frames(of: "1")[11]!
        let drag = s.beginDrag(grab(11, at: CGPoint(x: tile.maxX - 1, y: tile.midY)), frame: tile)!
        _ = s.perform(.fullscreen)
        let plan = s.dragEdges(drag, by: CGSize(width: 50, height: 0))
        #expect(plan == nil)
    }

    @Test func aFloatingWindowResizesFromTheCornerNearestThePress() throws {
        var s = Session(names: ["1"], display: display)
        _ = s.add(20, floating: true)
        let frame = CGRect(x: 100, y: 100, width: 400, height: 300)
        let topLeft = try #require(s.beginDrag(grab(20, at: CGPoint(x: 150, y: 150)), frame: frame))
        #expect(topLeft.floating && topLeft.edges == [.left, .up])
        #expect(s.resized(topLeft, by: CGSize(width: 50, height: -20)) == CGRect(x: 150, y: 80, width: 350, height: 320))
        #expect(s.resized(topLeft, by: CGSize(width: 1000, height: 1000)) == CGRect(x: 480, y: 380, width: 20, height: 20))
        let bottomRight = try #require(s.beginDrag(grab(20, at: CGPoint(x: 300, y: 250)), frame: frame))
        #expect(bottomRight.edges == [.right, .down])
        #expect(s.resized(bottomRight, by: CGSize(width: 30, height: -500)) == CGRect(x: 100, y: 100, width: 430, height: 20))
        _ = s.setMinimum(20, CGSize(width: 200, height: 0))
        #expect(s.resized(bottomRight, by: CGSize(width: -1000, height: 0)).width == 200)
    }
}
