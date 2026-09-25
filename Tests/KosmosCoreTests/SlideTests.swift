import CoreGraphics
import Testing
@testable import KosmosCore

private let left = CGRect(x: 10, y: 35, width: 945, height: 1035)
private let right = CGRect(x: 965, y: 35, width: 945, height: 1035)
private let narrow = CGRect(x: 1438, y: 35, width: 472, height: 1035)
/// Where an app opened a new window.
private let opened = CGRect(x: 600, y: 300, width: 480, height: 300)

private func bezier(_ p1: Double, _ p2: Double, _ u: Double) -> Double {
    3 * (1 - u) * (1 - u) * u * p1 + 3 * (1 - u) * u * u * p2 + u * u * u
}

private func close(_ a: CGRect, _ b: CGRect) -> Bool {
    abs(a.minX - b.minX) < 1e-6 && abs(a.minY - b.minY) < 1e-6 && abs(a.width - b.width) < 1e-6 && abs(a.height - b.height) < 1e-6
}

/// easeOutQuint is the point of cubic-bezier(0.23, 1, 0.32, 1) whose x is t.
@Test func easeFollowsOmarchysCurve() {
    #expect(Slide.ease(0) == 0)
    #expect(Slide.ease(1) == 1)
    for u in stride(from: 0.05, to: 1, by: 0.05) {
        #expect(abs(Slide.ease(bezier(0.23, 0.32, u)) - bezier(1, 1, u)) < 1e-6)
    }
    let samples = stride(from: 0.0, through: 1, by: 0.01).map(Slide.ease)
    #expect(zip(samples, samples.dropFirst()).allSatisfy { $0 <= $1 })
    #expect(Slide.ease(0.2) > 0.6)   // most of the way early, as easeOutQuint is
}

/// Each corner of where the window shows maps to the same corner of the window, in the
/// window's own coordinates.
@Test(arguments: [(left, left), (right, left), (left, narrow), (narrow.scaled(0.87), narrow)])
func transformShowsTheWindowAtTheShownFrame(shown: CGRect, actual: CGRect) {
    let transform = Slide.transform(showing: shown, at: actual)
    for (u, v) in [(0.0, 0.0), (1, 0), (0, 1), (1, 1), (0.5, 0.25)] {
        let screen = CGPoint(x: shown.minX + shown.width * u - actual.minX, y: shown.minY + shown.height * v - actual.minY)
        let window = screen.applying(transform)
        #expect(abs(window.x - actual.width * u) < 1e-6 && abs(window.y - actual.height * v) < 1e-6)
    }
}

@Test func moveRunsFromTheOldFrameToTheTarget() {
    let slide = Slide.move(from: left, to: right, at: 0)
    #expect(slide.shown(at: 0).frame == left)
    #expect(slide.shown(at: -1).frame == left)
    #expect(!slide.isOver(at: Slide.moveDuration / 2))
    #expect(slide.shown(at: Slide.moveDuration).frame == right)
    #expect(slide.isOver(at: Slide.moveDuration))
    #expect(slide.shown(at: 0).alpha == 1 && slide.shown(at: 0.2).alpha == 1)
}

@Test func popGrowsFromTheCenterAndFadesIn() {
    let slide = Slide.pop(to: narrow, at: 0)
    let start = slide.shown(at: 0)
    #expect(close(start.frame, CGRect(x: narrow.midX - narrow.width * 0.435, y: narrow.midY - narrow.height * 0.435,
                                      width: narrow.width * 0.87, height: narrow.height * 0.87)))
    #expect(start.alpha == 0)
    #expect(slide.shown(at: Slide.popDuration / 2).alpha > 0.5)
    #expect(close(slide.shown(at: Slide.popDuration).frame, narrow))
    #expect(abs(slide.shown(at: Slide.popDuration).alpha - 1) < 1e-9)
}

/// A relayout mid-slide continues from where the window shows, at the alpha it has there.
@Test func retargetingContinuesFromTheShownFrame() {
    let pop = Slide.pop(to: narrow, at: 0)
    let moved = pop.retargeted(to: right, at: 0.05)
    #expect(close(moved.shown(at: 0.05).frame, pop.shown(at: 0.05).frame))
    #expect(abs(moved.shown(at: 0.05).alpha - pop.shown(at: 0.05).alpha) < 1e-9)
    #expect(moved.duration == Slide.moveDuration)
    #expect(close(moved.shown(at: 0.05 + Slide.moveDuration).frame, right))
    #expect(abs(moved.shown(at: 0.05 + Slide.moveDuration).alpha - 1) < 1e-9)
}

private func move() -> SlidingWindow {
    SlidingWindow(space: 7, display: 1, from: left, to: right, pop: false, at: 0)
}

/// A write lands once WindowServer has the frame the worker read back, whichever of the two
/// comes first, and the reads follow each frame WindowServer gives the window until then.
@Test func aWriteLandsAtTheFrameReadBack() {
    var window = SlidingWindow(space: 7, display: 1, from: left, to: narrow, pop: false, at: 0)
    let resized = CGRect(origin: left.origin, size: narrow.size)
    let sizeLanded = window.observed(resized, at: 0.004)   // the size landed before the position
    let readAgain = window.observed(resized, at: 0.005)
    #expect(sizeLanded && !readAgain)
    window.confirmed(target: narrow, readBack: narrow, at: 0.008)
    #expect(window.landed == nil && window.isAwaiting(at: 0.009))
    let moved = window.observed(narrow, at: 0.010)
    #expect(moved && window.landed == 0.010 && !window.isAwaiting(at: 0.011))

    var readFirst = move()
    _ = readFirst.observed(right, at: 0.009)
    readFirst.confirmed(target: right, readBack: right, at: 0.012)
    #expect(readFirst.landed == 0.012)
}

/// A slide that is over holds the window at its end until the write lands, for the landing
/// wait at most, and then it ends.
@Test func aSlideOverHoldsItsEndUntilTheWriteLands() {
    var window = move()
    var done = window.step(at: 0.1)
    #expect(!done && window.shown != left && window.shown != right)
    done = window.step(at: 0.5)
    #expect(!done && window.shown == right && window.alpha == 1)
    done = window.step(at: 0.99)
    #expect(!done && window.isAwaiting(at: 0.99))
    done = window.step(at: SlidingWindow.landingWait)
    #expect(done && !window.isAwaiting(at: SlidingWindow.landingWait))

    var late = move()
    done = late.step(at: 0.5)
    late.confirmed(target: right, readBack: right, at: 0.6)
    _ = late.observed(right, at: 0.61)
    #expect(!done)
    done = late.step(at: 0.62)
    #expect(done)
}

/// A window that refuses the move reads back where it was, which WindowServer has already: it
/// lands at once and slides back there, with no wait.
@Test func aRefusedMoveLandsAtOnce() {
    var window = move()
    _ = window.step(at: 0.01)
    window.confirmed(target: right, readBack: left, at: 0.012)
    #expect(window.landed == 0.012 && !window.isAwaiting(at: 0.013))
    #expect(window.slide?.to == left)
    var done = window.step(at: 0.3)
    #expect(!done)
    done = window.step(at: 0.012 + Slide.moveDuration)
    #expect(done)
}

/// A new window stays transparent until its write lands, then pops in where it landed.
@Test func aPopWaitsForItsWriteThenPopsWhereItLanded() {
    var window = SlidingWindow(space: 7, display: 1, from: opened, to: narrow, pop: true, at: 0)
    var done = window.step(at: 0.01)
    #expect(!done && window.alpha == 0 && window.slide == nil)
    window.confirmed(target: narrow, readBack: narrow, at: 0.012)
    _ = window.observed(narrow, at: 0.015)
    done = window.step(at: 0.016)
    #expect(!done && close(window.shown, narrow.scaled(Slide.popScale)) && window.alpha == 0)
    done = window.step(at: 0.2)
    #expect(!done && window.alpha > 0.5)
    done = window.step(at: 0.016 + Slide.popDuration)
    #expect(done)
}

/// A pop whose write has not landed after the pop wait, as a launching app's, pops in at its
/// target, and the reads follow the write until the landing wait.
@Test func aLatePopStartsAtItsTargetAndFollowsTheWrite() {
    var window = SlidingWindow(space: 7, display: 1, from: opened, to: narrow, pop: true, at: 0)
    var done = window.step(at: SlidingWindow.popWait - 0.01)
    #expect(!done && window.slide == nil)
    done = window.step(at: SlidingWindow.popWait)
    #expect(!done && window.slide?.to == narrow && window.isAwaiting(at: 0.5))
    window.confirmed(target: narrow, readBack: narrow, at: 0.6)
    _ = window.observed(narrow, at: 0.7)
    #expect(window.landed == 0.7)
    done = window.step(at: SlidingWindow.popWait + Slide.popDuration)
    #expect(done)
}

/// A write to the slide's target that does not slide, as the retry after a refused size, is
/// followed again; one to another target ends the slide. A read back of an older write is
/// left out.
@Test func writesDuringASlide() {
    var window = move()
    window.confirmed(target: right, readBack: right, at: 0.01)
    _ = window.observed(right, at: 0.012)
    #expect(!window.isAwaiting(at: 0.1))
    var took = window.wrote(right, sliding: false, at: 0.1)
    #expect(took && window.isAwaiting(at: 0.1) && window.landed == nil)

    took = window.wrote(narrow, sliding: true, at: 0.2)
    #expect(took && window.slide?.to == narrow)
    window.confirmed(target: right, readBack: right, at: 0.21)
    #expect(window.readBack == nil)
    took = window.wrote(left, sliding: false, at: 0.3)
    #expect(!took)
}
