import CoreGraphics
import Testing
@testable import KosmosCore

// MARK: Insert

@Test func insertIntoEmptyWorkspace() {
    var workspace = Workspace()
    workspace.insert(1)
    #expect(workspace.tree == "h[1]")
    #expect(workspace.shares == [1])
}

@Test func insertWithoutFocusAppends() {
    var workspace = Workspace(orientation: .vertical)
    for window: WindowID in 1...3 {
        workspace.insert(window)
    }
    #expect(workspace.tree == "v[1 2 3]")
}

@Test func insertGoesAfterFocusedWindow() {
    var workspace = Workspace("h[1 2 3]")
    workspace.focus(1)
    workspace.insert(4)
    #expect(workspace.tree == "h[1 4 2 3]")
    #expect(workspace.shares == [0.25, 0.25, 0.25, 0.25])
}

@Test func insertGoesIntoFocusedWindowsContainer() {
    var workspace = Workspace("h[1 v[2 3]]")
    workspace.focus(2)
    workspace.insert(4)
    #expect(workspace.tree == "h[1 v[2 4 3]]")
    #expect(workspace.shares(around: 4) == [0.333, 0.333, 0.333])
}

@Test func insertTakesMeanShareOfSiblings() {
    var workspace = Workspace("h[1:3 2:1]")
    workspace.focus(2)
    workspace.insert(3)
    #expect(workspace.shares == [0.5, 0.167, 0.333])
}

@Test func insertIgnoresFloatingFocus() {
    var workspace = Workspace("h[1 2]")
    workspace.focus(1)
    workspace.float(2)
    workspace.focus(2)
    workspace.insert(3)
    #expect(workspace.tree == "h[1 3]")
}

// MARK: Remove

@Test func removeKeepsSiblingRatios() {
    var workspace = Workspace("h[1:1 2:1 3:2]")
    #expect(workspace.remove(1) == true)
    #expect(workspace.tree == "h[2 3]")
    #expect(workspace.shares == [0.333, 0.667])
}

@Test func removeCollapsesContainerLeftWithOneChild() {
    var workspace = Workspace("h[1:1 v[2 3]:3]")
    workspace.remove(2)
    #expect(workspace.tree == "h[1 3]")
    #expect(workspace.shares == [0.25, 0.75])
}

@Test func removeSplicesChildWithParentsOrientation() {
    var workspace = Workspace("h[1 v[2 h[3 4]]]")
    workspace.remove(2)
    #expect(workspace.tree == "h[1 3 4]")
    #expect(workspace.shares == [0.5, 0.25, 0.25])
}

@Test func removeReplacesRootLeftWithOneContainer() {
    var workspace = Workspace("h[1 v[2 3]]")
    workspace.remove(1)
    #expect(workspace.tree == "v[2 3]")
}

@Test func removeLastWindowKeepsEmptyRoot() {
    var workspace = Workspace("v[1]")
    workspace.remove(1)
    #expect(workspace.tree == "v[]")
    workspace.insert(2)
    #expect(workspace.tree == "v[2]")
}

@Test func removeFloatingAndParkedWindows() {
    var workspace = Workspace("h[1 2 3]")
    workspace.float(2)
    workspace.park(3)
    #expect(workspace.remove(2) == true)
    #expect(workspace.remove(3) == true)
    #expect(workspace.tree == "h[1]")
    #expect(workspace.floating.isEmpty)
    #expect(!workspace.contains(3))
    #expect(workspace.validate().isEmpty)
}

@Test func removeUnknownWindow() {
    var workspace = Workspace("h[1]")
    #expect(workspace.remove(2) == false)
}

@Test func removeForgetsFocus() {
    var workspace = Workspace("h[1 2]")
    workspace.focus(1)
    workspace.remove(1)
    #expect(workspace.focusedWindow == nil)
}

// MARK: Normalize

@Test func spliceKeepsSizesOnScreen() {
    var workspace = Workspace(unchecked: "h[1 h[2:3 3:7]]")
    let before = workspace.frames(in: screen, gaps: Gaps())
    workspace.normalize()
    #expect(workspace.tree == "h[1 2 3]")
    #expect(workspace.shares == [0.5, 0.15, 0.35])
    #expect(workspace.frames(in: screen, gaps: Gaps()) == before)
}

@Test func collapseKeepsSizeOnScreen() {
    var workspace = Workspace(unchecked: "h[1:1 v[2]:3]")
    let before = workspace.frames(in: screen, gaps: Gaps())
    workspace.normalize()
    #expect(workspace.tree == "h[1 2]")
    #expect(workspace.frames(in: screen, gaps: Gaps()) == before)
}

@Test func normalizeDropsEmptyContainers() {
    var workspace = Workspace(unchecked: "h[1 v[] v[2 h[]]]")
    workspace.normalize()
    #expect(workspace.tree == "h[1 2]")
}

// MARK: Validate

@Test func validateAcceptsSoundWorkspaces() {
    #expect(Workspace().validate().isEmpty)
    #expect(Workspace("h[1]").validate().isEmpty)
    #expect(Workspace("h[1 v[2 h[3 4]]]").validate().isEmpty)
}

@Test(arguments: [
    ("h[1 v[2]]", "fewer than two children"),
    ("h[1 v[]]", "fewer than two children"),
    ("h[1 h[2 3]]", "nests in"),
    ("h[v[1 2]]", "the root holds a single container"),
    ("h[1 1]", "window 1 is in 2 places"),
])
func validateReportsBrokenTrees(tree: String, problem: String) {
    let problems = Workspace(unchecked: tree).validate()
    #expect(problems.contains { $0.contains(problem) }, "\(problems)")
}

@Test func validateReportsBadWeights() {
    var workspace = Workspace("h[1 2]")
    workspace.root.children[0].weight = 0
    #expect(workspace.validate().contains { $0.contains("weight 0.0") })
    workspace.root.children[0].weight = .nan
    #expect(workspace.validate().contains { $0.contains("weight nan") })
    workspace.root.children[0].weight = 0.7
    #expect(workspace.validate() == ["weights in h[1 2] sum to 1.2"])
}

@Test func validateReportsWindowsInTwoPlaces() {
    var workspace = Workspace("h[1 2]")
    workspace.floating.append(1)
    #expect(workspace.validate() == ["window 1 is in 2 places"])
    workspace.floating = []
    workspace.parked.append(Parked(window: 2, floating: true))
    #expect(workspace.validate() == ["window 2 is in 2 places"])
}

@Test func validateReportsStaleState() {
    var workspace = Workspace("h[1]")
    workspace.fullscreenWindow = 2
    workspace.stamps[3] = 1
    workspace.parked.append(Parked(window: 4, floating: false))
    #expect(Set(workspace.validate()) == [
        "fullscreen window 2 is not tiled",
        "unknown window 3 has a focus stamp",
        "parked window 4 has no restore hint",
    ])
}
