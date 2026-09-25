import CoreGraphics
import Testing
@testable import KosmosCore

private let left = CGRect(x: 0, y: 0, width: 800, height: 600)
private let right = CGRect(x: 800, y: 0, width: 800, height: 600)
private let half = CGRect(x: 400, y: 0, width: 400, height: 600)

@Test func easeRunsFromZeroToOne() {
    #expect(Tween.ease(0) == 0)
    #expect(Tween.ease(0.5) == 0.5)
    #expect(Tween.ease(1) == 1)
    #expect(Tween.ease(0.25) < 0.25)
    #expect(Tween.ease(0.75) > 0.75)
}

@Test func sameSizeTweenMovesOnlyThenFinishes() {
    var tween = Tween(from: left, to: right, start: 0, duration: 0.2)
    for now in stride(from: 0.01, to: 0.2, by: 0.01) {
        guard case .position = tween.step(at: now) else {
            Issue.record("expected a position step at \(now)")
            return
        }
    }
    #expect(tween.step(at: 0.2) == .finish)
    #expect(!tween.sized)
}

@Test func resizingTweenWritesTheSizeOnceAtTheMidpoint() {
    var tween = Tween(from: left, to: half, start: 0, duration: 0.2)
    var frames = 0
    for now in stride(from: 0.01, to: 0.2, by: 0.01) {
        if case .frame(let frame) = tween.step(at: now) {
            frames += 1
            #expect(frame.size == half.size)
        }
    }
    #expect(frames == 1)
    #expect(tween.step(at: 0.25) == .finish)
}

@Test func lateTickStillEndsOnTime() {
    var tween = Tween(from: left, to: right, start: 0, duration: 0.2)
    _ = tween.step(at: 0.01)
    #expect(tween.step(at: 0.5) == .finish)
    #expect(tween.steps == 1)
}

@Test func retargetStartsWhereTheWindowIs() {
    var tween = Tween(from: left, to: half, start: 0, duration: 0.2)
    _ = tween.step(at: 0.05)
    let now = 0.05
    let next = tween.retargeted(to: right, at: now)
    #expect(next.from == tween.frame(at: now))
    #expect(next.from.size == left.size)   // the midpoint size write has not run
    #expect(next.start == now)
}
