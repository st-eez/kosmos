import CoreGraphics
import Testing
@testable import KosmosCore

private let left = Monitor(id: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 800))
private let right = Monitor(id: 2, frame: CGRect(x: 1000, y: 0, width: 1000, height: 800))
private let blue = BorderColor(hex: "#7aa2f7")!
private let from = CGRect(x: 100, y: 100, width: 500, height: 300)
private let to = CGRect(x: 1200, y: 100, width: 500, height: 300)

private struct Pooled: Equatable {
    var number: Int
    var display: DisplayID
}

/// Border windows made so far, numbered from 1.
private final class Maker {
    var made: [Pooled] = []

    func make(_ display: DisplayID, _: CGRect) -> Pooled {
        made.append(Pooled(number: made.count + 1, display: display))
        return made.last!
    }
}

private func shown(_ frame: CGRect, sliding: Bool) -> ShownBorder {
    let border = Border(around: frame, radius: 16, width: 2, color: blue, displays: [left, right],
                        path: sliding ? frame.union(to) : nil)!
    return ShownBorder(border: border, level: 0, alpha: 1, sliding: sliding)
}

private func blank(_ next: ShownBorder, on monitor: Monitor) -> ShownBorder {
    var blank = next
    (blank.border.display, blank.border.displayFrame, blank.alpha) = (monitor.id, monitor.frame, 0)
    return blank
}

@Test func aSlidingRingMovesToTheWindowReadyOnTheOtherDisplay() {
    var pool = BorderPool<Pooled>()
    let maker = Maker()
    func show(_ shown: [WindowID: ShownBorder], fullscreen: Set<DisplayID> = []) -> [BorderPool<Pooled>.Step] {
        pool.show(shown, fullscreen: fullscreen, make: maker.make)
    }
    let start = shown(from, sliding: true)
    // A ring's new window shows nothing until the slide places the ring, and goes to the slide
    // once every new window is ordered in.
    let (onLeft, onRight) = (Pooled(number: 2, display: 1), Pooled(number: 1, display: 2))
    #expect(show([9: start]) == [.orderIn(onLeft, target: 9, blank(start, on: left)),
                                 .ready(onRight, target: 9, blank(start, on: right)), .hand([9: [onRight, onLeft]])])
    let mid = shown(CGRect(x: 400, y: 100, width: 500, height: 300), sliding: true)
    #expect(show([9: mid]) == [.show(onLeft, target: 9, mid, pin: false), .hand([9: [onRight, onLeft]])])
    // Past the edge: only layers change, and the window left stays ready.
    let past = shown(CGRect(x: 800, y: 100, width: 500, height: 300), sliding: true)
    #expect(show([9: past]) == [.clear(onLeft), .show(onRight, target: 9, past, pin: true), .hand([9: [onLeft, onRight]])])
    #expect(pool.ordered(below: 9) == [onLeft, onRight])
    // A new write back to the left display.
    let back = shown(CGRect(x: 450, y: 100, width: 500, height: 300), sliding: true)
    #expect(show([9: back]) == [.clear(onRight), .show(onLeft, target: 9, back, pin: true), .hand([9: [onRight, onLeft]])])
    // The slide's end takes the rings back, then puts the ready window back, and the next
    // slide takes the window from the pool. Held, with its ring showing, 9 moves once the ring
    // goes to the slide, before the ready window is ordered in.
    let end = shown(from, sliding: false)
    #expect(show([9: end]) == [.hand([:]), .putBack(onRight), .show(onLeft, target: 9, end, pin: false)])
    #expect(pool.ordered(below: 9) == [onLeft])
    #expect(pool.show([9: start], held: [9], fullscreen: [], make: maker.make)
        == [.show(onLeft, target: 9, start, pin: false), .hand([9: [onLeft]]),
            .ready(onRight, target: 9, blank(start, on: right)), .hand([9: [onRight, onLeft]])])
    #expect(maker.made.count == 2)
}

@Test func aSlideThatEndsOrCloses() {
    var pool = BorderPool<Pooled>()
    let maker = Maker()
    _ = pool.show([9: shown(from, sliding: true)], fullscreen: [], make: maker.make)
    let (onLeft, onRight) = (maker.made[1], maker.made[0])
    // Ended on the right display, the window ready there, which a display frame moved the ring
    // into, stays ordered in as the ring's.
    let landed = shown(to, sliding: false)
    let steps = pool.show([9: landed], fullscreen: [], make: maker.make)
    #expect(steps == [.hand([:]), .putBack(onLeft), .show(onRight, target: 9, landed, pin: true)])
    // Closed: its windows go back to their pools.
    _ = pool.show([9: shown(from, sliding: true)], fullscreen: [], make: maker.make)
    let putBack = pool.show([:], fullscreen: [], make: maker.make).compactMap { step -> Int? in
        if case .putBack(let window) = step { window.number } else { nil }
    }
    #expect(Set(putBack) == [1, 2])
    #expect(pool.ordered(below: 9).isEmpty && maker.made.count == 2)
}

@Test func noWindowIsReadyOnADisplayThatMayShowAFullscreenSpace() {
    var pool = BorderPool<Pooled>()
    let maker = Maker()
    let start = shown(from, sliding: true)
    let onLeft = Pooled(number: 1, display: 1)
    #expect(pool.show([9: start], fullscreen: [2], make: maker.make) == [.orderIn(onLeft, target: 9, blank(start, on: left)),
                                                                         .hand([9: [onLeft]])])
    // The ring's window there waits for its Space move before it shows, and the slide has only
    // the window it left until then.
    let past = shown(CGRect(x: 800, y: 100, width: 500, height: 300), sliding: true)
    let onRight = Pooled(number: 2, display: 2)
    #expect(pool.show([9: past], fullscreen: [2], make: maker.make) == [.clear(onLeft), .hand([9: [onLeft]]), .wait(onRight, target: 9)])
    #expect(pool.ordered(below: 9) == [onLeft])
    let later = shown(CGRect(x: 900, y: 100, width: 500, height: 300), sliding: true)
    #expect(pool.show([9: later], fullscreen: [2], make: maker.make) == [.hand([9: [onLeft]])])
    // It shows nothing until the slide places the ring.
    #expect(pool.moved(onRight, of: 9) == blank(later, on: right) && pool.moved(onRight, of: 9) == nil)
    #expect(pool.handOff() == .hand([9: [onLeft, onRight]]))
}

@Test func aWindowTheSlideMayStillPlaceARingInLeavesItBeforeItGoesBack() {
    var pool = BorderPool<Pooled>()
    let maker = Maker()
    _ = pool.show([9: shown(from, sliding: true)], fullscreen: [], make: maker.make)
    let (onLeft, onRight) = (maker.made[1], maker.made[0])
    // Focus moved from 9, still sliding, to 8, and 9's ring window is given to 8 in the same
    // steps, so the slide lets go of both of 9's windows first.
    let other = shown(from, sliding: false)
    #expect(pool.show([8: other], fullscreen: [], make: maker.make)
        == [.hand([:]), .putBack(onLeft), .putBack(onRight), .orderIn(onLeft, target: 8, other)])
}

@Test func theFirstHandOffComesRightAfterTheSlidingTargetsStepsOnTheirWindows() {
    var pool = BorderPool<Pooled>()
    let maker = Maker()
    let (atRest, below) = (shown(from, sliding: false), shown(CGRect(x: 100, y: 450, width: 500, height: 300), sliding: false))
    _ = pool.show([8: atRest], fullscreen: [], make: maker.make)
    _ = pool.show([8: atRest, 9: shown(from, sliding: true)], fullscreen: [], make: maker.make)
    let (ring8, ready9, ring9) = (maker.made[0], maker.made[1], maker.made[2])
    // 8 begins to slide, held with its ring showing, as 9 loses its border and 7 gets one. The
    // first hand-off takes 9's windows from the slide before they go back to their pools, and
    // 8 moves before any of them is put back or ordered in again.
    let start = shown(from, sliding: true)
    #expect(pool.show([8: start, 7: below], held: [8], fullscreen: [], make: maker.make) == [
        .show(ring8, target: 8, start, pin: false), .hand([8: [ring8]]),
        .putBack(ring9), .putBack(ready9), .orderIn(ring9, target: 7, below),
        .ready(ready9, target: 8, blank(start, on: right)), .hand([8: [ready9, ring8]])])
}

@Test func aHeldTargetWhoseRingGoesMovesOnceItIsPutBack() {
    var pool = BorderPool<Pooled>()
    let maker = Maker()
    _ = pool.show([8: shown(from, sliding: false)], fullscreen: [], make: maker.make)
    // 8 begins to slide, held with its ring showing, as the focus goes to 5, which slides and
    // takes 8's window. 5's windows show nothing until the slide places its ring, and go to
    // the slide only once ordered in.
    let start = shown(from, sliding: true)
    let (window, ready) = (maker.made[0], Pooled(number: 2, display: 2))
    #expect(pool.show([5: start], held: [8], fullscreen: [], make: maker.make) == [
        .putBack(window), .hand([:]),
        .orderIn(window, target: 5, blank(start, on: left)), .ready(ready, target: 5, blank(start, on: right)),
        .hand([5: [ready, window]])])
}
