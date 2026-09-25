import CoreGraphics
import Testing
@testable import KosmosCore

// MARK: Focus in a direction

@Test func focusReachesSibling() {
    var workspace = Workspace("h[1 2 3]")
    #expect(workspace.focus(.right, from: 1) == 2)
    #expect(workspace.focusedWindow == 2)
    #expect(workspace.focus(.left, from: 3) == 2)
}

@Test func focusStopsAtWorkspaceEdge() {
    var workspace = Workspace("h[1 2]")
    #expect(workspace.focus(.left, from: 1) == nil)
    #expect(workspace.focus(.up, from: 1) == nil)
    #expect(workspace.focus(.right, from: 2) == nil)
}

@Test func focusClimbsToContainerAlongDirection() {
    var workspace = Workspace("h[1 v[2 h[3 4]]]")
    #expect(workspace.focus(.left, from: 3) == 1)
    #expect(workspace.focus(.up, from: 4) == 2)
    #expect(workspace.focus(.down, from: 4) == nil)
}

@Test func focusDescendsByFocusOrder() {
    var workspace = Workspace("h[1 v[2 h[3 4]]]")
    #expect(workspace.focus(.right, from: 1) == 4)
    workspace.focus(2)
    workspace.focus(1)
    #expect(workspace.focus(.right, from: 1) == 2)
    workspace.focus(3)
    workspace.focus(1)
    #expect(workspace.focus(.right, from: 1) == 3)
}

@Test func focusIgnoresWindowsOutsideTheTree() {
    var workspace = Workspace("h[1 2]")
    workspace.float(2)
    #expect(workspace.focus(.left, from: 2) == nil)
    #expect(workspace.focus(.left, from: 9) == nil)
}

@Test func focusInDirectionEndsFullscreen() {
    var workspace = Workspace("h[1 2]")
    workspace.toggleFullscreen(1)
    #expect(workspace.focus(.right, from: 1) == 2)
    #expect(workspace.fullscreenWindow == nil)
}

// MARK: Focus in a direction with floating windows

@Test func focusReachesFloatingWindowCenteredBetweenTiles() {
    var workspace = Workspace("h[1 2]")
    workspace.floating = [9]
    // Centered on the gap between the tiles.
    let frames: [WindowID: CGRect] = [9: CGRect(x: 300, y: 100, width: 400, height: 400)]
    #expect(workspace.focus(.right, from: 1, frames: frames) == 9)
    #expect(workspace.focusedWindow == 9)
    #expect(workspace.focus(.right, from: 9, frames: frames) == 2)
    #expect(workspace.focus(.left, from: 2, frames: frames) == 9)
    #expect(workspace.focus(.left, from: 9, frames: frames) == 1)
    #expect(workspace.focus(.up, from: 9, frames: frames) == nil)
    #expect(workspace.tree == "h[1 2]")
}

@Test func floatingWindowsStandBesideTheTileUnderTheirCenter() {
    let cases: [(tree: String, floating: [WindowID], frames: [WindowID: CGRect], tiled: String)] = [
        // Off the display, past tile 2's center.
        ("h[1 2]", [9], [9: CGRect(x: 800, y: 200, width: 400, height: 200)], "h[1 2 9]"),
        // Covering tile 1: a center at the tile's own goes after it.
        ("h[1 2]", [9], [9: CGRect(x: 10, y: 10, width: 485, height: 580)], "h[1 9 2]"),
        // Overlapping, both between the tiles, 9 left of 8.
        ("h[1 2]", [8, 9], [8: CGRect(x: 350, y: 100, width: 400, height: 400),
                            9: CGRect(x: 250, y: 100, width: 400, height: 400)], "h[1 9 8 2]"),
        // In tile 2, below its center: into tile 2's container.
        ("h[1 v[2 3]]", [9], [9: CGRect(x: 650, y: 150, width: 200, height: 200)], "h[1 v[2 9 3]]"),
        // With no tiles, first in the root, by their centers.
        ("h[]", [1, 3, 2], [1: CGRect(x: 0, y: 0, width: 100, height: 100),
                            2: CGRect(x: 10, y: 10, width: 100, height: 100),
                            3: CGRect(x: 20, y: 20, width: 100, height: 100)], "h[1 2 3]"),
        // With no frame, nowhere.
        ("h[1 2]", [8], [:], "h[1 2]"),
    ]
    for (tree, floating, frames, tiled) in cases {
        var workspace = Workspace(tree)
        workspace.floating = floating
        #expect(workspace.withFloatingTiled(frames, in: screen, gaps: deskGaps, minimums: [:]).tree == tiled, "\(frames)")
    }
}

/// AeroSpace's placement marks the floating window most recently focused (docs/tree.md).
@Test func focusDescendsByEachWindowsOwnFocusOrder() {
    var workspace = Workspace("h[1 v[2 3]]")
    workspace.floating = [9]
    workspace.focus(9)
    workspace.focus(3)
    let frames: [WindowID: CGRect] = [9: CGRect(x: 650, y: 150, width: 200, height: 200)]
    #expect(workspace.focus(.right, from: 1, frames: frames) == 3)
}

// MARK: Swap

@Test func swapExchangesPlacesAndKeepsShares() {
    var workspace = Workspace("h[1:1 2:3]")
    #expect(workspace.swap(1, .right) == true)
    #expect(workspace.tree == "h[2 1]")
    #expect(workspace.shares == [0.25, 0.75])
}

@Test func swapReachesFocusedWindowOfContainer() {
    var workspace = Workspace("h[1 v[2 3]]")
    workspace.focus(2)
    #expect(workspace.swap(1, .right) == true)
    #expect(workspace.tree == "h[2 v[1 3]]")
    #expect(workspace.swap(3, .left) == true)
    #expect(workspace.tree == "h[3 v[1 2]]")
}

@Test func swapStopsAtWorkspaceEdge() {
    var workspace = Workspace("h[1 2]")
    #expect(workspace.swap(1, .left) == false)
    #expect(workspace.swap(1, .down) == false)
    #expect(workspace.tree == "h[1 2]")
}

// MARK: Move

@Test func moveSwapsWithSiblingWindowAndKeepsShares() {
    var workspace = Workspace("h[1:3 2:1 3:1]")
    #expect(workspace.move(1, .right) == true)
    #expect(workspace.tree == "h[2 1 3]")
    #expect(workspace.shares == [0.2, 0.6, 0.2])
}

@Test func moveStopsAtWorkspaceEdge() {
    var workspace = Workspace("h[1 v[2 3] 4]")
    #expect(workspace.move(1, .left) == false)
    #expect(workspace.move(4, .right) == false)
    #expect(workspace.tree == "h[1 v[2 3] 4]")
    var single = Workspace("h[1]")
    #expect(single.move(1, .up) == false)
    #expect(single.move(1, .left) == false)
    #expect(single.tree == "h[1]")
    #expect(single.move(9, .left) == false)
}

@Test func moveAcrossRootWrapsIt() {
    var workspace = Workspace("h[1 2 3]")
    #expect(workspace.move(1, .up) == true)
    #expect(workspace.tree == "v[1 h[2 3]]")
    var other = Workspace("h[1 2]")
    #expect(other.move(1, .down) == true)
    #expect(other.tree == "v[2 1]")
    var nested = Workspace("h[1 v[2 3]]")
    #expect(nested.move(3, .down) == true)
    #expect(nested.tree == "v[h[1 2] 3]")
}

@Test func moveWithoutImplicitContainerStopsWhereNoContainerAboveRunsAlong() {
    let edges: [(String, WindowID, Direction)] = [("h[1 2 3]", 1, .up), ("h[1 v[2 3]]", 3, .down), ("v[h[1 2] 3]", 1, .left)]
    for (tree, window, direction) in edges {
        var workspace = Workspace(tree)
        #expect(workspace.move(window, direction, implicitContainer: false) == false, "\(tree) \(window) \(direction)")
        #expect(workspace.tree == tree)
    }
    // A container above that runs along the direction still takes the window.
    var workspace = Workspace("h[1 v[2 3]]")
    #expect(workspace.move(3, .right, implicitContainer: false) == true)
    #expect(workspace.tree == "h[1 2 3]")
}

@Test func moveEntersSiblingContainerBesideFocusedChild() {
    var workspace = Workspace("h[1 v[2 3] 4]")
    workspace.focus(2)
    #expect(workspace.move(1, .right) == true)
    #expect(workspace.tree == "h[v[2 1 3] 4]")
    #expect(workspace.shares(around: 1) == [0.333, 0.333, 0.333])
    #expect(workspace.shares == [0.5, 0.5])
}

@Test func moveEntersNestedContainerAtFacingEdge() {
    var workspace = Workspace("h[1 v[2 h[3 4]] 5]")
    workspace.focus(4)
    #expect(workspace.move(1, .right) == true)
    #expect(workspace.tree == "h[v[2 h[1 3 4]] 5]")
    #expect(workspace.move(5, .left) == true)
    #expect(workspace.tree == "v[2 h[1 3 4 5]]")
}

@Test func moveLeavesContainerNextToIt() {
    var left = Workspace("h[1 v[2 3]]")
    #expect(left.move(3, .left) == true)
    #expect(left.tree == "h[1 3 2]")
    var right = Workspace("h[1 v[2 3]]")
    #expect(right.move(3, .right) == true)
    #expect(right.tree == "h[1 2 3]")
}

@Test func moveLeavesNestedContainers() {
    var workspace = Workspace("h[1 v[2 h[3 v[4 5]]]]")
    #expect(workspace.move(5, .left) == true)
    #expect(workspace.tree == "h[1 v[2 h[3 5 4]]]")
    var up = Workspace("h[1 v[2 h[3 v[4 5]]]]")
    #expect(up.move(4, .up) == true)
    #expect(up.tree == "h[1 v[2 4 h[3 5]]]")
}

@Test func moveOutEntersBorderingContainer() {
    var workspace = Workspace("h[v[1 2] v[3 4]]")
    workspace.focus(3)
    #expect(workspace.move(1, .right) == true)
    #expect(workspace.tree == "h[2 v[3 1 4]]")
}

@Test func moveIgnoresWindowsOutsideTheTree() {
    var workspace = Workspace("h[1 2]")
    workspace.float(2)
    #expect(workspace.move(2, .left) == false)
}

// MARK: Join with

@Test func joinWithWindowWrapsBoth() {
    var right = Workspace("h[1 2 3]")
    #expect(right.joinWith(1, .right) == true)
    #expect(right.tree == "h[v[1 2] 3]")
    #expect(right.shares == [0.667, 0.333])      // 3 keeps its third
    var left = Workspace("h[1 2 3]")
    #expect(left.joinWith(3, .left) == true)
    #expect(left.tree == "h[1 v[2 3]]")
    #expect(left.shares == [0.333, 0.667])
}

@Test func joinWithContainerJoinsIt() {
    var workspace = Workspace("h[1 v[2 3] 4]")
    #expect(workspace.joinWith(1, .right) == true)
    #expect(workspace.tree == "h[v[1 2 3] 4]")
    #expect(workspace.shares(around: 1) == [0.333, 0.333, 0.333])
    #expect(workspace.joinWith(4, .left) == true)
    #expect(workspace.tree == "v[1 2 3 4]")
}

@Test func joinWithClimbsToContainerAlongDirection() {
    var workspace = Workspace("h[1 v[2 3]]")
    #expect(workspace.joinWith(3, .left) == true)
    #expect(workspace.tree == "h[v[1 3] 2]")
}

@Test func joinWithOnlySiblingTurnsTheRoot() {
    var workspace = Workspace("h[1 2]")
    #expect(workspace.joinWith(1, .right) == true)
    #expect(workspace.tree == "v[1 2]")
}

@Test func joinWithStopsAtWorkspaceEdge() {
    var workspace = Workspace("h[1 2]")
    #expect(workspace.joinWith(1, .left) == false)
    #expect(workspace.joinWith(1, .up) == false)
    #expect(workspace.tree == "h[1 2]")
}

// MARK: Layout

@Test func layoutSplicesContainerIntoParent() {
    var workspace = Workspace("h[1 v[2 3] 4]")
    #expect(workspace.layout(2, .horizontal) == true)
    #expect(workspace.tree == "h[1 2 3 4]")
    #expect(workspace.shares == [0.333, 0.167, 0.167, 0.333])
}

@Test func layoutOnRootSplicesChildren() {
    var workspace = Workspace("h[1 v[2 3]]")
    #expect(workspace.layout(1, .vertical) == true)
    #expect(workspace.tree == "v[1 2 3]")
    #expect(workspace.shares == [0.5, 0.25, 0.25])
}

@Test func layoutLeavesAncestorsAlone() {
    var workspace = Workspace("h[1 v[2 h[3 4]]]")
    #expect(workspace.layout(3, .vertical) == true)
    #expect(workspace.tree == "h[1 v[2 3 4]]")
}

@Test func layoutAlreadySetIsNoop() {
    var workspace = Workspace("h[1 2]")
    #expect(workspace.layout(1, .horizontal) == false)
    #expect(workspace.layout(9, .vertical) == false)
}

@Test func toggleLayoutFlipsOrientation() {
    var workspace = Workspace("h[1 2]")
    #expect(workspace.toggleLayout(1) == true)
    #expect(workspace.tree == "v[1 2]")
    #expect(workspace.toggleLayout(2) == true)
    #expect(workspace.tree == "h[1 2]")
    #expect(workspace.toggleLayout(9) == false)
}

// MARK: Resize

@Test func resizeGrowsWindowByPoints() {
    var workspace = Workspace("h[1 2]")
    #expect(workspace.resize(1, .width, by: 100, in: screen, gaps: Gaps()) == true)
    let frames = workspace.frames(in: screen, gaps: Gaps())
    #expect(frames[1]!.width == 600)
    #expect(frames[2]!.width == 400)
}

@Test func resizeTakesFromSiblingsInProportion() {
    var workspace = Workspace("h[1:2 2:1 3:1]")
    #expect(workspace.resize(1, .width, by: -100, in: screen, gaps: Gaps()) == true)
    let frames = workspace.frames(in: screen, gaps: Gaps())
    #expect([1, 2, 3].map { frames[$0]!.width } == [400, 300, 300])
}

@Test func resizeAcrossContainerResizesAncestor() {
    var workspace = Workspace("v[h[1 2] 3]")
    #expect(workspace.resize(1, .height, by: 60, in: screen, gaps: Gaps()) == true)
    let frames = workspace.frames(in: screen, gaps: Gaps())
    #expect([1, 2, 3].map { frames[$0]!.height } == [360, 360, 240])
}

@Test func resizeSmartFollowsWindowsContainer() {
    var workspace = Workspace("h[1 v[2 3]]")
    #expect(workspace.resize(2, .smart, by: 60, in: screen, gaps: Gaps()) == true)
    let frames = workspace.frames(in: screen, gaps: Gaps())
    #expect([1, 2, 3].map { frames[$0]!.size } == [
        CGSize(width: 500, height: 600),
        CGSize(width: 500, height: 360),
        CGSize(width: 500, height: 240),
    ])
}

@Test func resizeCountsOnlySpaceBetweenGaps() {
    let gaps = Gaps(inner: 10, outer: Insets(top: 20, left: 20, bottom: 20, right: 20))
    var workspace = Workspace("h[1 2]")
    let before = workspace.frames(in: screen, gaps: gaps)
    workspace.resize(1, .width, by: 100, in: screen, gaps: gaps)
    let after = workspace.frames(in: screen, gaps: gaps)
    #expect(after[1]!.width == before[1]!.width + 100)
    #expect(after[2]!.width == before[2]!.width - 100)
}

@Test func resizeStopsAtOnePoint() {
    var workspace = Workspace("h[1 2]")
    #expect(workspace.resize(1, .width, by: 500, in: screen, gaps: Gaps()) == true)
    #expect(workspace.frames(in: screen, gaps: Gaps())[2]!.width == 1)
    #expect(workspace.resize(1, .width, by: 100, in: screen, gaps: Gaps()) == false)
    #expect(workspace.resize(1, .width, by: -1500, in: screen, gaps: Gaps()) == true)
    let frames = workspace.frames(in: screen, gaps: Gaps())
    #expect([1, 2].map { frames[$0]!.width } == [1, 999])
}

@Test func resizeKeepsNestedWindowsAtOnePoint() {
    let display = CGRect(x: 0, y: 0, width: 1728, height: 1000)
    var workspace = Workspace("h[1 v[2 h[3 4]]]")
    #expect(workspace.resize(1, .width, by: 900, in: display, gaps: Gaps()) == true)
    let frames = workspace.frames(in: display, gaps: Gaps())
    #expect([2, 3, 4].map { frames[$0]!.width } == [2, 1, 1])
    #expect(workspace.resize(1, .width, by: 1, in: display, gaps: Gaps()) == false)
}

@Test func resizeStopsAtAMinimum() {
    let display = CGRect(x: 0, y: 0, width: 1728, height: 1000)
    let minimums = [WindowID(2): CGSize(width: 740, height: 0)]
    var workspace = Workspace("h[1 2]")
    #expect(workspace.resize(1, .width, by: 200, in: display, gaps: Gaps(), minimums: minimums) == true)
    var frames = workspace.frames(in: display, gaps: Gaps(), minimums: minimums)
    #expect([1, 2].map { frames[$0]!.width } == [988, 740])
    #expect(workspace.resize(1, .width, by: 200, in: display, gaps: Gaps(), minimums: minimums) == false)
    #expect(workspace.resize(2, .width, by: -50, in: display, gaps: Gaps(), minimums: minimums) == false)
    #expect(workspace.resize(1, .width, by: -100, in: display, gaps: Gaps(), minimums: minimums) == true)
    frames = workspace.frames(in: display, gaps: Gaps(), minimums: minimums)
    #expect([1, 2].map { frames[$0]!.width } == [888, 840])
}

@Test func resizeStopsAtANestedMinimumAcross() {
    let display = CGRect(x: 0, y: 0, width: 1728, height: 1000)
    let minimums = [WindowID(3): CGSize(width: 400, height: 0)]
    var workspace = Workspace("h[1 v[2 h[3 4]]]")
    #expect(workspace.resize(1, .width, by: 600, in: display, gaps: Gaps(), minimums: minimums) == true)
    let frames = workspace.frames(in: display, gaps: Gaps(), minimums: minimums)
    #expect(frames[3]!.width == 400)
    #expect(frames[1]!.width > 864)
    #expect(workspace.resize(1, .width, by: 1, in: display, gaps: Gaps(), minimums: minimums) == false)
}

@Test func resizeNeedsSiblingsAlongDimension() {
    var single = Workspace("h[1]")
    #expect(single.resize(1, .width, by: 10, in: screen, gaps: Gaps()) == false)
    var pair = Workspace("h[1 2]")
    #expect(pair.resize(1, .height, by: 10, in: screen, gaps: Gaps()) == false)
    pair.float(2)
    #expect(pair.resize(2, .width, by: 10, in: screen, gaps: Gaps()) == false)
}

// MARK: Move an edge

@Test func movingAnEdgeTakesFromTheNeighbourNextToItAlone() {
    var workspace = Workspace("h[1 2 3]")
    let before = workspace.frames(in: screen, gaps: Gaps())
    #expect(workspace.moveEdge(2, .right, by: 100, in: screen, gaps: Gaps(), minimums: [:]) == true)
    var frames = workspace.frames(in: screen, gaps: Gaps())
    #expect(frames[1] == before[1])
    #expect(frames[2]!.minX == before[2]!.minX && frames[2]!.maxX == before[2]!.maxX + 100)
    #expect(frames[3]!.maxX == before[3]!.maxX)
    // Inward, and on the other side.
    #expect(workspace.moveEdge(2, .left, by: -50, in: screen, gaps: Gaps(), minimums: [:]) == true)
    frames = workspace.frames(in: screen, gaps: Gaps())
    #expect(frames[1]!.maxX == before[1]!.maxX + 50 && frames[2]!.maxX == before[2]!.maxX + 100)
    // With two windows beyond it, only the one next to the edge gives the space.
    let middle = frames
    #expect(workspace.moveEdge(3, .left, by: 50, in: screen, gaps: Gaps(), minimums: [:]) == true)
    frames = workspace.frames(in: screen, gaps: Gaps())
    #expect(frames[1] == middle[1] && frames[2]!.maxX == middle[2]!.maxX - 50 && frames[3]!.minX == middle[3]!.minX - 50)
}

@Test func movingAnEdgeKeepsTheLengthsOfNestedNeighbors() {
    var workspace = Workspace("h[1 v[h[2 3] 4]]")
    let before = workspace.frames(in: screen, gaps: Gaps())
    // The root gives the column 100 pt from 1, and inside it only 2 grows: 3 stays.
    #expect(workspace.moveEdge(2, .left, by: 100, in: screen, gaps: Gaps(), minimums: [:]) == true)
    let frames = workspace.frames(in: screen, gaps: Gaps())
    #expect(frames[1]!.width == before[1]!.width - 100)
    #expect(frames[2]!.minX == before[2]!.minX - 100 && frames[2]!.maxX == before[2]!.maxX)
    #expect(frames[3] == before[3])
    #expect(frames[4]!.minX == before[4]!.minX - 100 && frames[4]!.maxX == before[4]!.maxX)
}

@Test func anEdgeAtTheWorkspacesEdgeStays() {
    var workspace = Workspace("h[1 v[h[2 3] 4]]")
    #expect(workspace.moveEdge(3, .right, by: 10, in: screen, gaps: Gaps(), minimums: [:]) == false)
    #expect(workspace.moveEdge(4, .down, by: 10, in: screen, gaps: Gaps(), minimums: [:]) == false)
    #expect(workspace.moveEdge(1, .up, by: 10, in: screen, gaps: Gaps(), minimums: [:]) == false)
}

@Test func movingAnEdgeStopsAtTheLimits() {
    var workspace = Workspace("h[1 2]")
    #expect(workspace.moveEdge(1, .right, by: 2000, in: screen, gaps: Gaps(), minimums: [:]) == true)
    #expect(workspace.frames(in: screen, gaps: Gaps())[2]!.width == 1)
    #expect(workspace.moveEdge(1, .right, by: 10, in: screen, gaps: Gaps(), minimums: [:]) == false)
    let minimums = [WindowID(1): CGSize(width: 300, height: 0)]
    #expect(workspace.moveEdge(2, .left, by: 900, in: screen, gaps: Gaps(), minimums: minimums) == true)
    #expect(workspace.frames(in: screen, gaps: Gaps())[1]!.width == 300)
}

// MARK: Balance and flatten

@Test func balanceSizesEqualizesEveryContainer() {
    var workspace = Workspace("h[1:1 v[2:1 3:3]:3]")
    workspace.balanceSizes()
    #expect(workspace.shares == [0.5, 0.5])
    #expect(workspace.shares(around: 2) == [0.5, 0.5])
}

@Test func flattenPutsEveryWindowUnderRoot() {
    var workspace = Workspace("h[1:3 v[2 h[3 4]]:1]")
    workspace.flattenWorkspaceTree()
    #expect(workspace.tree == "h[1 2 3 4]")
    #expect(workspace.shares == [0.25, 0.25, 0.25, 0.25])
    var empty = Workspace()
    empty.flattenWorkspaceTree()
    #expect(empty.tree == "h[]")
}

/// Joining a window into its neighbor and back out, as Ctrl-Alt-Left then Ctrl-Alt-Up does,
/// must not grow the window left alone. It grew by a sixth of the width on every cycle.
@Test func joinAndUnjoinLeaveOtherWindowsAlone() {
    let screen = CGRect(x: 0, y: 0, width: 1728, height: 1000)
    var w = Workspace("h[1 2 3]")
    for _ in 1...5 {
        #expect(w.joinWith(3, .left) == true)
        var f = w.frames(in: screen, gaps: Gaps(), minimums: [:])
        #expect(f[1]!.width == 576)                       // untouched by the join
        #expect(f[2]!.width == 1152 && f[3]!.width == 1152)
        #expect(w.joinWith(3, .up) == true)                // unjoin
        f = w.frames(in: screen, gaps: Gaps(), minimums: [:])
        #expect([f[1]!.width, f[2]!.width, f[3]!.width] == [576, 576, 576])
    }
}
