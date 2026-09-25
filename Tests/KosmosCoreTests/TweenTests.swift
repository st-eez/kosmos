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

/// A move writes positions only; a resize writes its size once, at the midpoint.
@Test(arguments: zip([right, half], [0, 1]))
func sizeIsWrittenOnlyAtTheMidpointOfAResize(to target: CGRect, frames expected: Int) {
    var tween = Tween(from: left, to: target, start: 0, duration: 0.2)
    var frames = 0
    for now in stride(from: 0.01, to: 0.2, by: 0.01) {
        switch tween.step(at: now) {
        case .frame(let frame)?:
            frames += 1
            #expect(frame.size == target.size)
        case .position?:
            break
        case nil:
            Issue.record("over at \(now)")
        }
    }
    #expect(frames == expected)
    #expect(tween.step(at: 0.2) == nil)
}
