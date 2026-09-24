import CoreGraphics
import Testing
@testable import KosmosCore

// MARK: Park and unpark

@Test func unparkReturnsToIndexAndShare() {
    var workspace = Workspace("h[1:1 2:2 3:1]")
    #expect(workspace.park(2) == true)
    #expect(workspace.tree == "h[1 3]")
    #expect(workspace.shares == [0.5, 0.5])
    #expect(workspace.contains(2))
    workspace.unpark([2])
    #expect(workspace.tree == "h[1 2 3]")
    #expect(workspace.shares == [0.25, 0.5, 0.25])
}

@Test(arguments: [WindowID(2), 3])
func unparkRebuildsCollapsedContainer(window: WindowID) {
    var workspace = Workspace("h[1 v[2:1 3:3]]")
    workspace.park(window)
    #expect(workspace.tree == (window == 2 ? "h[1 3]" : "h[1 2]"))
    workspace.unpark([window])
    #expect(workspace.tree == "h[1 v[2 3]]")
    #expect(workspace.shares == [0.5, 0.5])
    #expect(workspace.shares(around: 2) == [0.25, 0.75])
}

@Test func unparkRebuildsReplacedRoot() {
    var workspace = Workspace("h[1:1 v[2 3]:2]")
    workspace.park(1)
    #expect(workspace.tree == "v[2 3]")
    workspace.unpark([1])
    #expect(workspace.tree == "h[1 v[2 3]]")
    #expect(workspace.shares == [0.333, 0.667])
}

@Test func appHideAndUnhideRestoresTheTree() {
    var workspace = Workspace("h[1:1 v[2:1 3:2]:2 4:1]")
    workspace.park(2)
    workspace.park(3)
    #expect(workspace.tree == "h[1 4]")
    workspace.unpark([2, 3])
    #expect(workspace.tree == "h[1 v[2 3] 4]")
    #expect(workspace.shares == [0.25, 0.5, 0.25])
    #expect(workspace.shares(around: 2) == [0.333, 0.667])
}

@Test func unparkAfterSiblingClosed() {
    var workspace = Workspace("h[1 2 3]")
    workspace.park(3)
    workspace.remove(2)
    workspace.unpark([3])
    #expect(workspace.tree == "h[1 3]")
    #expect(workspace.shares == [0.5, 0.5])
}

@Test func unparkClimbsWhenEverySiblingIsGone() {
    var workspace = Workspace("h[1:1 v[2 3]:2 4:1]")
    workspace.park(3)
    workspace.remove(2)
    workspace.unpark([3])
    #expect(workspace.tree == "h[1 3 4]")
    #expect(workspace.shares == [0.25, 0.5, 0.25])
}

@Test func unparkFallsBackToFocusedWindow() {
    var workspace = Workspace("h[1 2]")
    workspace.park(2)
    workspace.remove(1)
    workspace.insert(3)
    workspace.insert(4)
    workspace.focus(3)
    workspace.unpark([2])
    #expect(workspace.tree == "h[3 2 4]")
}

@Test func unparkInParkingOrderRestoresTheTree() {
    let display = CGRect(x: 0, y: 0, width: 1728, height: 1000)
    var workspace = Workspace("h[1 2 3]")
    workspace.park(1)
    workspace.park(2)
    workspace.unpark([1])
    #expect(workspace.tree == "h[1 3]")
    #expect(workspace.frames(in: display, gaps: Gaps())[1]!.width == 864)
    workspace.unpark([2])
    #expect(workspace.tree == "h[1 2 3]")
    let frames = workspace.frames(in: display, gaps: Gaps())
    #expect([1, 2, 3].map { frames[$0]!.width } == [576, 576, 576])
}

@Test func repeatedParkingDoesNotDrift() {
    var workspace = Workspace("h[1 2 3]")
    let original = workspace
    for _ in 0..<50 {
        workspace.park(1)
        workspace.park(2)
        workspace.unpark([1])
        workspace.unpark([2])
    }
    #expect(workspace.sameTree(as: original), "\(workspace.detailed)")
}

/// Every order of parking three windows, each followed by every order of unparking them
/// one at a time, gives back the same tree and sizes.
@Test(arguments: permutations([2, 4, 5]), permutations([2, 4, 5]))
func unparkInAnyOrderRestoresTheTree(parking: [WindowID], unparking: [WindowID]) {
    var workspace = Workspace("h[1:2 v[2 h[3 4:3]]:3 5:1]")
    let original = workspace
    for window in parking {
        workspace.park(window)
    }
    for window in unparking {
        workspace.unpark([window])
    }
    #expect(workspace.sameTree(as: original), "\(workspace.detailed)")
}

@Test func staleHintDoesNotSkewLaterReturns() {
    var workspace = Workspace("h[1 2]")
    workspace.float(2)
    workspace.insert(3)
    let before = workspace
    for _ in 0..<10 {
        workspace.park(1)
        workspace.unpark([1])
    }
    #expect(workspace.sameTree(as: before), "\(workspace.detailed)")
    workspace.tile(2)
    #expect(workspace.tree == "h[1 2 3]")
    #expect(workspace.shares == [0.25, 0.25, 0.5])
}

@Test func unparkRebuildsContainerBelowRoot() {
    var workspace = Workspace("h[1 v[2:1 h[3 4]:3]]")
    workspace.park(2)
    #expect(workspace.tree == "h[1 3 4]")
    workspace.unpark([2])
    #expect(workspace.tree == "h[1 v[2 h[3 4]]]")
    #expect(workspace.shares == [0.5, 0.5])
    #expect(workspace.shares(around: 2) == [0.25, 0.75])
    #expect(workspace.shares(around: 3) == [0.5, 0.5])
}

@Test func tileRebuildsContainerBelowRoot() {
    var workspace = Workspace("h[1 v[h[2 3] 4]]")
    workspace.float(4)
    #expect(workspace.tree == "h[1 2 3]")
    workspace.tile(4)
    #expect(workspace.tree == "h[1 v[h[2 3] 4]]")
    #expect(workspace.shares == [0.5, 0.5])
}

@Test func parkOnlyWindow() {
    var workspace = Workspace("v[1]")
    workspace.park(1)
    #expect(workspace.tree == "v[]")
    workspace.unpark([1])
    #expect(workspace.tree == "v[1]")
}

@Test func parkedFloatingWindowReturnsToFloating() {
    var workspace = Workspace("h[1 2]")
    workspace.float(2)
    workspace.park(2)
    #expect(workspace.floating.isEmpty)
    workspace.unpark([2])
    #expect(workspace.floating == [2])
    #expect(workspace.tree == "h[1]")
    workspace.tile(2)
    #expect(workspace.tree == "h[1 2]")
}

@Test func parkIgnoresUnknownAndUnparkIgnoresUnparked() {
    var workspace = Workspace("h[1 2]")
    #expect(workspace.park(3) == false)
    workspace.park(1)
    #expect(workspace.park(1) == false)
    workspace.unpark([2, 3])
    #expect(workspace.tree == "h[2]")
}

@Test func parkEndsFullscreen() {
    var workspace = Workspace("h[1 2]")
    workspace.toggleFullscreen(1)
    workspace.park(1)
    #expect(workspace.fullscreenWindow == nil)
}

@Test func parkedWindowKeepsFocusStamp() {
    var workspace = Workspace("h[1 2]")
    workspace.focus(2)
    workspace.focus(1)
    workspace.park(1)
    #expect(workspace.focusedWindow == 2)
    workspace.unpark([1])
    #expect(workspace.focusedWindow == 1)
}

// MARK: Floating and tiling

@Test func floatAndTileReturnsToPlace() {
    var workspace = Workspace("h[1 v[2 3] 4]")
    #expect(workspace.float(3) == true)
    #expect(workspace.tree == "h[1 2 4]")
    #expect(workspace.floating == [3])
    #expect(workspace.tile(3) == true)
    #expect(workspace.tree == "h[1 v[2 3] 4]")
    #expect(workspace.floating.isEmpty)
}

@Test func tileWithoutHintGoesAfterFocusedWindow() {
    var workspace = Workspace("h[1 2]")
    workspace.floating.append(3)
    workspace.focus(1)
    workspace.tile(3)
    #expect(workspace.tree == "h[1 3 2]")
}

@Test func floatAndTileRejectWrongState() {
    var workspace = Workspace("h[1 2]")
    #expect(workspace.tile(1) == false)
    workspace.float(2)
    #expect(workspace.float(2) == false)
    #expect(workspace.float(9) == false)
}

@Test func floatEndsFullscreen() {
    var workspace = Workspace("h[1 2]")
    workspace.toggleFullscreen(1)
    workspace.float(1)
    #expect(workspace.fullscreenWindow == nil)
}

// MARK: Fullscreen and focus

@Test func fullscreenCoversDisplayRectangle() {
    var workspace = Workspace("h[1 2]")
    let gaps = Gaps(inner: 10, outer: Insets(top: 10, left: 10, bottom: 10, right: 10))
    let tiled = workspace.frames(in: screen, gaps: gaps)
    #expect(workspace.toggleFullscreen(1) == true)
    let frames = workspace.frames(in: screen, gaps: gaps)
    #expect(frames[1] == screen)
    #expect(frames[2] == tiled[2])
    #expect(workspace.toggleFullscreen(1) == true)
    #expect(workspace.frames(in: screen, gaps: gaps) == tiled)
}

@Test func fullscreenTracksOneWindow() {
    var workspace = Workspace("h[1 2 3]")
    workspace.toggleFullscreen(1)
    #expect(workspace.fullscreenWindow == 1)
    #expect(workspace.focusedWindow == 1)
    workspace.toggleFullscreen(2)
    #expect(workspace.fullscreenWindow == 2)
    #expect(workspace.focusedWindow == 2)
    workspace.float(3)
    #expect(workspace.toggleFullscreen(3) == false)
    #expect(workspace.toggleFullscreen(9) == false)
    #expect(workspace.fullscreenWindow == 2)
}

@Test func focusOnAnotherTiledWindowEndsFullscreen() {
    var workspace = Workspace("h[1 2 3]")
    workspace.float(3)
    workspace.toggleFullscreen(1)
    workspace.focus(1)
    workspace.focus(3)
    #expect(workspace.fullscreenWindow == 1)
    workspace.focus(2)
    #expect(workspace.fullscreenWindow == nil)
}

@Test func focusedWindowFollowsFocus() {
    var workspace = Workspace("h[1 2 3]")
    #expect(workspace.focusedWindow == nil)
    workspace.float(3)
    workspace.focus(3)
    workspace.focus(9)
    #expect(workspace.focusedWindow == 3)
    workspace.focus(1)
    #expect(workspace.focusedWindow == 1)
}
