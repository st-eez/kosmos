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
    #expect(right.shares == [0.5, 0.5])
    var left = Workspace("h[1 2 3]")
    #expect(left.joinWith(3, .left) == true)
    #expect(left.tree == "h[1 v[2 3]]")
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

@Test func resizeRefusesToLeaveLessThanOnePoint() {
    var workspace = Workspace("h[1 2]")
    #expect(workspace.resize(1, .width, by: 500, in: screen, gaps: Gaps()) == false)
    #expect(workspace.resize(1, .width, by: -500, in: screen, gaps: Gaps()) == false)
    #expect(workspace.shares == [0.5, 0.5])
    #expect(workspace.resize(1, .width, by: 498, in: screen, gaps: Gaps()) == true)
    #expect(workspace.frames(in: screen, gaps: Gaps())[2]!.width == 2)
}

@Test func resizeNeedsSiblingsAlongDimension() {
    var single = Workspace("h[1]")
    #expect(single.resize(1, .width, by: 10, in: screen, gaps: Gaps()) == false)
    var pair = Workspace("h[1 2]")
    #expect(pair.resize(1, .height, by: 10, in: screen, gaps: Gaps()) == false)
    pair.float(2)
    #expect(pair.resize(2, .width, by: 10, in: screen, gaps: Gaps()) == false)
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
