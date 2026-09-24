import CoreGraphics
import Testing
@testable import KosmosCore

// MARK: Frames

@Test func framesSplitByWeight() {
    let frames = Workspace("h[1 v[2:1 3:2]]").frames(in: screen, gaps: Gaps())
    #expect(frames == [
        1: CGRect(x: 0, y: 0, width: 500, height: 600),
        2: CGRect(x: 500, y: 0, width: 500, height: 200),
        3: CGRect(x: 500, y: 200, width: 500, height: 400),
    ])
}

@Test func framesUseSwayInnerGaps() {
    let frames = Workspace("h[1 2 3]").frames(in: screen, gaps: Gaps(inner: 10))
    #expect(frames == [
        1: CGRect(x: 0, y: 0, width: 327, height: 600),
        2: CGRect(x: 337, y: 0, width: 326, height: 600),
        3: CGRect(x: 673, y: 0, width: 327, height: 600),
    ])
}

@Test func outerGapsInsetTheRectangle() {
    let gaps = Gaps(inner: 10, outer: Insets(top: 40, left: 10, bottom: 10, right: 10))
    let frames = Workspace("v[1 2]").frames(in: screen, gaps: gaps)
    #expect(frames == [
        1: CGRect(x: 10, y: 40, width: 980, height: 270),
        2: CGRect(x: 10, y: 320, width: 980, height: 270),
    ])
}

@Test func sizesAddUpToTheContainer() {
    let frames = Workspace("h[1 2 3 4 5 6 7]").frames(in: screen, gaps: Gaps())
    var edge: CGFloat = 0
    for window: WindowID in 1...7 {
        let frame = frames[window]!
        #expect(frame.minX == edge)
        #expect(frame.width == 142 || frame.width == 143)
        edge = frame.maxX
    }
    #expect(edge == 1000)
}

@Test func gapsShrinkInSmallRectangles() {
    let narrow = CGRect(x: 0, y: 0, width: 250, height: 100)
    let inner = Workspace("h[1 2 3]").frames(in: narrow, gaps: Gaps(inner: 50))
    #expect([1, 2, 3].map { inner[$0]!.width } == [83, 84, 83])
    #expect(inner[3]!.maxX == 250)

    let outer = Gaps(outer: Insets(left: 40, right: 40))
    let single = Workspace("h[1]").frames(in: CGRect(x: 0, y: 0, width: 150, height: 100), gaps: outer)
    #expect(single[1] == CGRect(x: 25, y: 0, width: 100, height: 100))
}

@Test(arguments: [
    CGRect.zero,
    CGRect(x: 100, y: 50, width: -100, height: -50),
    CGRect(x: 0, y: 0, width: 3, height: 1),
])
func degenerateRectanglesGiveNoNegativeSizes(rect: CGRect) {
    let gaps = Gaps(inner: 10, outer: Insets(top: 10, left: 10, bottom: 10, right: 10))
    let frames = Workspace("h[1 v[2 h[3 4]] 5]").frames(in: rect, gaps: gaps)
    #expect(frames.count == 5)
    for frame in frames.values {
        #expect(frame.width >= 0 && frame.height >= 0)
        #expect(rect.standardized.contains(frame) || frame.isEmpty)
    }
}

@Test func tinyWeightGetsNoSpaceAndNoNegativeSize() {
    let frames = Workspace("h[1:0.000001 2:1]").frames(in: screen, gaps: Gaps(inner: 10))
    #expect(frames[1]!.width == 0)
    #expect(frames[2]!.width == 990)
}

@Test func framesHaveWholePointEdges() {
    let rect = CGRect(x: 0.5, y: 0.25, width: 999.3, height: 600.6)
    let gaps = Gaps(inner: 7.5, outer: Insets(top: 3.3, left: 3.3, bottom: 3.3, right: 3.3))
    for frame in Workspace("h[1 v[2 h[3 4 5]] 6]").frames(in: rect, gaps: gaps).values {
        for edge in [frame.minX, frame.minY, frame.maxX, frame.maxY] {
            #expect(edge == edge.rounded())
        }
    }
}

@Test func framesCoverOnlyTiledWindows() {
    var workspace = Workspace("h[1 2 3]")
    workspace.float(2)
    workspace.park(3)
    #expect(Array(workspace.frames(in: screen, gaps: Gaps()).keys) == [1])
    #expect(Workspace().frames(in: screen, gaps: Gaps()).isEmpty)
}
