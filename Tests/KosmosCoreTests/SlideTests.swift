import CoreGraphics
import Testing
@testable import KosmosCore

private let left = CGRect(x: 10, y: 35, width: 945, height: 1035)
private let right = CGRect(x: 965, y: 35, width: 945, height: 1035)
private let narrow = CGRect(x: 1438, y: 35, width: 472, height: 1035)

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

/// To show the window moved by d, the transform is a translation of -d.
@Test func transformOfAMoveIsTheOppositeTranslation() {
    #expect(Slide.transform(showing: left, at: left) == .identity)
    #expect(Slide.transform(showing: left, at: right) == CGAffineTransform(translationX: right.minX - left.minX, y: 0))
}

@Test func moveRunsFromTheOldFrameToTheTarget() {
    let slide = Slide.move(from: left, to: right, at: 0)
    #expect(slide.shown(at: 0) == left)
    #expect(slide.shown(at: -1) == left)
    #expect(!slide.isOver(at: Slide.moveDuration / 2))
    #expect(slide.shown(at: Slide.moveDuration) == right)
    #expect(slide.isOver(at: Slide.moveDuration))
    #expect(slide.alpha(at: 0) == 1 && slide.alpha(at: 0.2) == 1)
}

@Test func popGrowsFromTheCenterAndFadesIn() {
    let slide = Slide.pop(to: narrow, at: 0)
    let start = slide.shown(at: 0)
    #expect(close(start, CGRect(x: narrow.midX - narrow.width * 0.435, y: narrow.midY - narrow.height * 0.435,
                                width: narrow.width * 0.87, height: narrow.height * 0.87)))
    #expect(slide.alpha(at: 0) == 0)
    #expect(slide.alpha(at: Slide.popDuration / 2) > 0.5)
    #expect(close(slide.shown(at: Slide.popDuration), narrow))
    #expect(abs(slide.alpha(at: Slide.popDuration) - 1) < 1e-9)
}

/// A relayout mid-slide continues from where the window shows, at the alpha it has there.
@Test func retargetingContinuesFromTheShownFrame() {
    let pop = Slide.pop(to: narrow, at: 0)
    let moved = pop.retargeted(to: right, at: 0.05)
    #expect(close(moved.shown(at: 0.05), pop.shown(at: 0.05)))
    #expect(abs(moved.alpha(at: 0.05) - pop.alpha(at: 0.05)) < 1e-9)
    #expect(moved.duration == Slide.moveDuration)
    #expect(close(moved.shown(at: 0.05 + Slide.moveDuration), right))
    #expect(abs(moved.alpha(at: 0.05 + Slide.moveDuration) - 1) < 1e-9)
}

/// The landed frame replaces the target as the end, so a window that rounded its size ends
/// where WindowServer has it.
@Test func landedFrameBecomesTheEnd() {
    var slide = Slide.move(from: left, to: right, at: 0)
    let rounded = CGRect(x: right.minX, y: right.minY, width: right.width - 3, height: right.height - 7)
    let before = slide.shown(at: 0.01)
    slide.to = rounded
    #expect(close(slide.shown(at: Slide.moveDuration), rounded))
    #expect(abs(slide.shown(at: 0.01).minX - before.minX) < 1e-6)
}
