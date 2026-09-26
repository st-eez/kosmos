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

// MARK: Minimums

/// Activity Monitor refuses widths under about 740 points.
@Test func minimumKeepsAWindowWholeAndOnScreen() {
    let display = CGRect(x: 0, y: 0, width: 1728, height: 1000)
    let minimums = [WindowID(2): CGSize(width: 740, height: 400)]
    let workspace = Workspace("h[1:7 2:3]")
    let frames = workspace.frames(in: display, gaps: Gaps(), minimums: minimums)
    #expect(frames[1] == CGRect(x: 0, y: 0, width: 988, height: 1000))
    #expect(frames[2] == CGRect(x: 988, y: 0, width: 740, height: 1000))
    #expect(workspace.shares == [0.7, 0.3])
    // With room again, the weights apply as the user set them.
    let wide = workspace.frames(in: CGRect(x: 0, y: 0, width: 3000, height: 1000), gaps: Gaps(), minimums: minimums)
    #expect([1, 2].map { wide[$0]!.width } == [2100, 900])
}

@Test func minimumsThatDoNotBindChangeNothing() {
    let workspace = Workspace("h[1:2 v[2 h[3 4:3]]:3 5]")
    let minimums = Dictionary(uniqueKeysWithValues: (1...5).map { (WindowID($0), CGSize(width: 20, height: 20)) })
    let gaps = Gaps(inner: 8, outer: Insets(top: 30, left: 8, bottom: 8, right: 8))
    #expect(workspace.frames(in: screen, gaps: gaps, minimums: minimums) == workspace.frames(in: screen, gaps: gaps))
}

@Test func nestedMinimumsWidenTheirContainers() {
    let display = CGRect(x: 0, y: 0, width: 1728, height: 1000)
    let minimums = [WindowID(3): CGSize(width: 600, height: 0), 4: CGSize(width: 600, height: 0)]
    let frames = Workspace("h[1 v[2 h[3 4]]]").frames(in: display, gaps: Gaps(), minimums: minimums)
    #expect(frames == [
        1: CGRect(x: 0, y: 0, width: 528, height: 1000),
        2: CGRect(x: 528, y: 0, width: 1200, height: 500),
        3: CGRect(x: 528, y: 500, width: 600, height: 500),
        4: CGRect(x: 1128, y: 500, width: 600, height: 500),
    ])
}

@Test func minimumsCountTheGapsBetweenWindows() {
    let display = CGRect(x: 0, y: 0, width: 1728, height: 1000)
    let gaps = Gaps(inner: 10, outer: Insets(top: 10, left: 10, bottom: 10, right: 10))
    let frames = Workspace("h[1 2]").frames(in: display, gaps: gaps, minimums: [2: CGSize(width: 900, height: 0)])
    #expect(frames[1] == CGRect(x: 10, y: 10, width: 798, height: 980))
    #expect(frames[2] == CGRect(x: 818, y: 10, width: 900, height: 980))
}

@Test func minimumsThatDoNotFitStayOnScreen() {
    let display = CGRect(x: 0, y: 0, width: 1728, height: 1000)
    let minimums = Dictionary(uniqueKeysWithValues: (1...3).map { (WindowID($0), CGSize(width: 700, height: 0)) })
    let workspace = Workspace("h[1 2 3]")
    let frames = workspace.frames(in: display, gaps: Gaps(), minimums: minimums)
    // 2100 points in 1728: each of the two seams overlaps by 186.
    #expect([1, 2, 3].map { frames[$0]!.minX } == [0, 514, 1028])
    #expect(frames.values.allSatisfy { $0.width == 700 && display.contains($0) })
    #expect(workspace.overlapping(in: display, gaps: Gaps(), minimums: minimums) == [1, 2, 3])
}

/// Steve's Helium beside Outlook on the 1920 by 1080 main panel with his gaps, after
/// `resize smart -100` on Outlook, once each kept its minimum (live log, September 25, 2026).
@Test func minimumsThatDoNotFitOverlapOnlyByTheirExcess() {
    let display = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let gaps = Gaps(inner: 10, outer: Insets(top: 35, left: 10, bottom: 10, right: 10))
    let workspace = Workspace("h[1:1045 2:845]")
    let minimums = [WindowID(1): CGSize(width: 785, height: 0), 2: CGSize(width: 1145, height: 0)]
    let frames = workspace.frames(in: display, gaps: gaps, minimums: minimums)
    // 785, 10 and 1145 make 1940 of the 1900 points: the seam loses its gap and overlaps by 30.
    #expect(frames[1] == CGRect(x: 10, y: 35, width: 785, height: 1035))
    #expect(frames[2] == CGRect(x: 765, y: 35, width: 1145, height: 1035))
    #expect(workspace.overlapping(in: display, gaps: gaps, minimums: minimums) == [1, 2])
    // The weights stay, so the split is theirs again once a minimum stops binding.
    #expect(workspace.frames(in: display, gaps: gaps, minimums: [2: CGSize(width: 1145, height: 0)])[1]!.width == 745)
    #expect(workspace.frames(in: display, gaps: gaps, minimums: [:]) == [
        1: CGRect(x: 10, y: 35, width: 1045, height: 1035), 2: CGRect(x: 1065, y: 35, width: 845, height: 1035),
    ])
    // Five points over take them from the gap, and nothing overlaps.
    let tight = [WindowID(1): CGSize(width: 750, height: 0), 2: minimums[2]!]
    let narrowed = workspace.frames(in: display, gaps: gaps, minimums: tight)
    #expect(narrowed[1]!.maxX == 760 && narrowed[2]!.minX == 765 && narrowed[2]!.maxX == 1910)
    #expect(workspace.overlapping(in: display, gaps: gaps, minimums: tight).isEmpty)
}

@Test func minimumLargerThanTheScreenIsCutToIt() {
    let display = CGRect(x: 0, y: 0, width: 1728, height: 1000)
    let frames = Workspace("v[1 2]").frames(in: display, gaps: Gaps(), minimums: [2: CGSize(width: 2000, height: 2000)])
    #expect(frames[2] == display)
    // With nothing left, a window with no minimum keeps the sane 60 points, over the other.
    #expect(frames[1] == CGRect(x: 0, y: 0, width: 1728, height: 60))
}
