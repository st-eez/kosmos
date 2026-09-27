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
    #expect(show([9: start]) == [.ready(Pooled(number: 1, display: 2), target: 9, blank(start, on: right)),
                                 .orderIn(Pooled(number: 2, display: 1), target: 9, start)])
    let (onLeft, onRight) = (maker.made[1], maker.made[0])
    let mid = shown(CGRect(x: 400, y: 100, width: 500, height: 300), sliding: true)
    #expect(show([9: mid]) == [.show(onLeft, target: 9, mid, pin: false)])
    // Past the edge: only layers change, and the window left stays ready.
    let past = shown(CGRect(x: 800, y: 100, width: 500, height: 300), sliding: true)
    #expect(show([9: past]) == [.clear(onLeft), .show(onRight, target: 9, past, pin: true)])
    #expect(pool.ordered(below: 9) == [onLeft, onRight])
    // A new write back to the left display.
    let back = shown(CGRect(x: 450, y: 100, width: 500, height: 300), sliding: true)
    #expect(show([9: back]) == [.clear(onRight), .show(onLeft, target: 9, back, pin: true)])
    // The slide's end puts the ready window back, and the next slide takes it from the pool.
    let end = shown(from, sliding: false)
    #expect(show([9: end]) == [.putBack(onRight), .show(onLeft, target: 9, end, pin: false)])
    #expect(pool.ordered(below: 9) == [onLeft])
    #expect(show([9: start]) == [.ready(onRight, target: 9, blank(start, on: right)), .show(onLeft, target: 9, start, pin: false)])
    #expect(maker.made.count == 2)
}

@Test func aSlideThatEndsOrCloses() {
    var pool = BorderPool<Pooled>()
    let maker = Maker()
    _ = pool.show([9: shown(from, sliding: true)], fullscreen: [], make: maker.make)
    let (onLeft, onRight) = (maker.made[1], maker.made[0])
    // Ended as the window reached the right display: the right one's pooled window shows it.
    let landed = shown(to, sliding: false)
    let steps = pool.show([9: landed], fullscreen: [], make: maker.make)
    #expect(steps == [.putBack(onLeft), .putBack(onRight), .orderIn(onRight, target: 9, landed)])
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
    #expect(pool.show([9: start], fullscreen: [2], make: maker.make) == [.orderIn(Pooled(number: 1, display: 1), target: 9, start)])
    // The ring's window there waits for its Space move before it shows.
    let past = shown(CGRect(x: 800, y: 100, width: 500, height: 300), sliding: true)
    let onRight = Pooled(number: 2, display: 2)
    #expect(pool.show([9: past], fullscreen: [2], make: maker.make) == [.clear(maker.made[0]), .wait(onRight, target: 9)])
    #expect(pool.ordered(below: 9) == [maker.made[0]])
    let later = shown(CGRect(x: 900, y: 100, width: 500, height: 300), sliding: true)
    #expect(pool.show([9: later], fullscreen: [2], make: maker.make).isEmpty)
    #expect(pool.moved(onRight, of: 9) == later && pool.moved(onRight, of: 9) == nil)
}
