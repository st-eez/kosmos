import CoreGraphics
import Foundation
import Testing
@testable import KosmosCore

/// A floating window in fullscreen covers what a tiled one does, and every way out of
/// fullscreen puts it back at its frame from before (docs/tree.md).
@Suite struct FloatingFullscreenTests {
    static let display = CGRect(x: 0, y: 0, width: 1000, height: 800)
    /// Floating window 3's frame before fullscreen.
    static let own = CGRect(x: 100, y: 120, width: 400, height: 300)

    /// Tiles 1 and 2 on workspace 1, and floating 3 in fullscreen, focused.
    static func session() -> Session {
        var s = Session(names: ["1", "2"], display: display)
        _ = s.add(1); _ = s.add(2); _ = s.add(3, floating: true)
        _ = s.adopt(3)
        #expect(s.perform(.fullscreen, frame: { $0 == 3 ? own : nil })?.frames[3] == display)
        return s
    }

    static func tiles() -> [WindowID: CGRect] {
        var s = Session(names: ["1"], display: display)
        _ = s.add(1)
        return s.add(2).frames
    }

    @Test func itCoversTheDisplayAndTogglesBackToItsFrame() {
        var s = Self.session()
        #expect(s.frames(of: "1") == Self.tiles().merging([3: Self.display]) { $1 })
        #expect(s.bordered.isEmpty)
        let plan = s.perform(.fullscreen, frame: { _ in Self.display })
        #expect(plan?.frames[3] == Self.own && plan?.frames[1] == Self.tiles()[1])
        #expect(s.workspaces["1"]!.fullscreenWindow == nil && s.frames(of: "1")[3] == nil)
        #expect(s.bordered == [1: false, 2: false, 3: true])
    }

    @Test func aFloatingWindowWithNoFrameStaysOutOfFullscreen() {
        var s = Session(names: ["1"], display: Self.display)
        _ = s.add(3, floating: true)
        #expect(s.perform(.fullscreen) == nil)
        #expect(s.workspaces["1"]!.fullscreenWindow == nil)
    }

    @Test func anotherWindowTakingFullscreenPutsItBack() {
        var s = Self.session()
        s.workspaces["1"]!.stamp(1)
        let plan = s.perform(.fullscreen)
        #expect(plan?.frames[1] == Self.display && plan?.frames[3] == Self.own)
    }

    // MARK: Focus

    @Test func focusOnATileEndsItAndAnotherFloatingWindowComesUpOverIt() {
        var s = Self.session()
        _ = s.add(4, floating: true)
        #expect(s.adopt(4).isEmpty)
        #expect(s.workspaces["1"]!.fullscreenWindow == 3)
        let plan = s.adopt(2)
        #expect(plan.frames[3] == Self.own && plan.frames[2] == Self.tiles()[2])
        #expect(s.workspaces["1"]!.fullscreenWindow == nil)
    }

    @Test func followingATileEndsIt() {
        var s = Self.session()
        let plan = s.follow(1)
        #expect(plan.frames[3] == Self.own && plan.focus == .window(1))
    }

    @Test func focusInADirectionReachesNoTileUnderIt() {
        var s = Self.session()
        #expect(s.perform(.focus(.left), frame: { $0 == 3 ? Self.display : nil }) == nil)
        #expect(s.workspaces["1"]!.fullscreenWindow == 3)
    }

    @Test func aNewWindowEndsItWhenKosmosAdoptsItsFocus() {
        var s = Self.session()
        #expect(s.add(5).frames[3] == Self.display)
        #expect(s.adopt(5).frames[3] == Self.own)
    }

    /// The tiled rule, which docs/tree.md keeps: adopting another tile lays the workspace out
    /// at once.
    @Test func adoptingAnotherTileLaysOutATiledFullscreenWindow() {
        var s = Session(names: ["1"], display: Self.display)
        _ = s.add(1); _ = s.add(2)
        _ = s.adopt(1)
        _ = s.perform(.fullscreen)
        #expect(s.adopt(2).frames == Self.tiles())
        #expect(s.adopt(1).isEmpty)
    }

    // MARK: Moving, closing and tiling

    @Test func movingItToAnotherWorkspaceEndsItThere() {
        var s = Self.session()
        let plan = s.perform(.moveNodeToWorkspace(.named("2"), focusFollowsWindow: false))
        #expect(plan?.frames[3] == Self.own && plan?.hide == [3])
        #expect(s.workspaces["1"]!.fullscreenWindow == nil && s.workspaces["2"]!.fullscreenWindow == nil)
        #expect(s.isFloating(3) && s.workspace(of: 3) == "2")
    }

    @Test func movingItToAnotherDisplayPutsItsFrameThere() {
        let left = Monitor(id: 1, frame: Self.display), right = Monitor(id: 2, frame: Self.display.offsetBy(dx: 1000, dy: 0))
        var s = Session(names: ["1", "2"], monitors: [left, right], assigned: ["1": 1, "2": 2])
        _ = s.add(3, floating: true)
        _ = s.perform(.fullscreen, frame: { _ in Self.own })
        let plan = s.perform(.moveNodeToMonitor(.direction(.right), focusFollowsWindow: true, wrapAround: false))
        #expect(plan?.frames[3] == Self.own.offsetBy(dx: 1000, dy: 0))
    }

    @Test func closingItEndsIt() {
        var s = Self.session()
        let plan = s.remove(3)
        #expect(plan.frames[3] == nil && s.workspaces["1"]!.fullscreenWindow == nil)
    }

    @Test func tilingItEndsIt() {
        var s = Self.session()
        let plan = s.perform(.layout(.toggleFloating))
        #expect(s.workspaces["1"]!.fullscreenWindow == nil && s.workspaces["1"]!.frameBeforeFullscreen == nil)
        #expect(plan?.frames[3] != Self.display && plan?.frames[3] != Self.own)
    }

    /// Floating 4 focused over it and tiled ends it, as a focus on a tile does.
    @Test func tilingAnotherFocusedWindowEndsIt() {
        var s = Self.session()
        _ = s.add(4, floating: true)
        _ = s.adopt(4)
        let plan = s.perform(.layout(.toggleFloating))
        #expect(s.workspaces["1"]!.fullscreenWindow == nil && plan?.frames[3] == Self.own)
        #expect(plan?.frames[4] == s.frames(of: "1")[4] && s.focused == 4)
    }

    /// The same where a rule on its title tiles it.
    @Test func aRetitledFocusedWindowTiledEndsIt() {
        var s = Self.session()
        _ = s.add(4, floating: true)
        _ = s.adopt(4)
        let plan = s.retitled(4, floating: false, frame: nil, to: nil)
        #expect(s.workspaces["1"]!.fullscreenWindow == nil && plan?.frames[3] == Self.own)
    }

    @Test func aTabSwitchPassesItOn() {
        var s = Self.session()
        _ = s.replace(3, with: 9)
        #expect(s.workspaces["1"]!.fullscreenWindow == 9)
        #expect(s.perform(.fullscreen)?.frames[9] == Self.own)
    }

    // MARK: Workspaces and displays

    @Test func switchingWorkspacesAndBackKeepsIt() {
        var s = Self.session()
        #expect(s.perform(.workspace(.named("2")))?.hide.contains(3) == true)
        let back = s.perform(.workspace(.named("1")))
        #expect(back?.show.contains(3) == true && back?.frames[3] == Self.display)
        #expect(s.workspaces["1"]!.fullscreenWindow == 3)
    }

    @Test func aDisplayChangeKeepsItOnTheWorkspacesDisplayAndItsFrameComesAlong() {
        let left = Monitor(id: 1, frame: Self.display), right = Monitor(id: 2, frame: Self.display.offsetBy(dx: 1000, dy: 0))
        var s = Session(names: ["1", "2"], monitors: [left, right], assigned: ["1": 1, "2": 2])
        _ = s.add(3, floating: true)
        _ = s.perform(.fullscreen, frame: { _ in Self.own })
        // Unplugged, the left display takes workspace 1 to the right one.
        s.reconfigure(names: ["1", "2"], monitors: [right], assigned: [:], merge: [:])
        #expect(s.resyncPlan(layingOutHidden: false).frames[3] == right.area)
        // On no display, the frame goes into the display's area.
        #expect(s.perform(.fullscreen)?.frames[3] == Self.own.offsetBy(dx: 900, dy: 0))
    }

    /// The laptop profile merges 6 to 0 into 1 to 5 at an unplug.
    @Test func aProfileMergingItsWorkspaceAwayKeepsItInFullscreen() {
        let left = Monitor(id: 1, frame: Self.display), right = Monitor(id: 2, frame: Self.display.offsetBy(dx: 1000, dy: 0))
        var s = Session(names: ["1", "2"], monitors: [left, right], assigned: ["1": 1, "2": 2])
        _ = s.add(3, to: "2", floating: true)
        _ = s.follow(3)
        _ = s.perform(.fullscreen, frame: { _ in Self.own.offsetBy(dx: 1000, dy: 0) })
        s.reconfigure(names: ["1"], monitors: [left], assigned: [:], merge: ["2": "1"])
        #expect(s.workspaces["1"]!.fullscreenWindow == 3 && s.resyncPlan(layingOutHidden: false).frames[3] == left.area)
        s.reconfigure(names: ["1", "2"], monitors: [left, right], assigned: ["1": 1, "2": 2], merge: [:])
        #expect(s.workspaces["1"]!.fullscreenWindow == nil && s.workspaces["2"]!.fullscreenWindow == 3)
        #expect(s.workspaces["2"]!.frameBeforeFullscreen == Self.own.offsetBy(dx: 1000, dy: 0))
    }

    /// The tile focused on the workspace it joins would sit under it, so it takes the focus.
    @Test func aProfileMergingItsWorkspaceAwayFocusesIt() {
        let left = Monitor(id: 1, frame: Self.display), right = Monitor(id: 2, frame: Self.display.offsetBy(dx: 1000, dy: 0))
        var s = Session(names: ["1", "2"], monitors: [left, right], assigned: ["1": 1, "2": 2])
        _ = s.add(1); _ = s.add(2)
        _ = s.add(5, to: "2", floating: true)
        _ = s.follow(5)
        _ = s.perform(.fullscreen, frame: { _ in Self.own.offsetBy(dx: 1000, dy: 0) })
        _ = s.follow(1)
        s.reconfigure(names: ["1"], monitors: [left], assigned: [:], merge: ["2": "1"])
        #expect(s.workspaces["1"]!.fullscreenWindow == 5 && s.focused == 5)
    }

    // MARK: Parking and drags

    @Test func parkingEndsItAndTheReturnGoesBackToItsFrame() {
        var s = Self.session()
        _ = s.park([3], because: .minimized)
        #expect(s.workspaces["1"]!.fullscreenWindow == nil)
        let plan = s.unpark([3], follow: 3)
        #expect(plan.frames[3] == Self.own && s.isFloating(3))
        #expect(s.unpark([3], follow: 3).frames[3] == nil)
    }

    /// No command leaves tile 2 focused under tile 1's fullscreen, so the test sets the stamp.
    /// A return elsewhere keeps 2 focused, which ends the fullscreen and lays workspace 1 out.
    @Test func aReturnElsewhereKeepingATileFocusedUnderItLaysItsWorkspaceOut() {
        var s = Session(names: ["1", "2"], display: Self.display)
        _ = s.add(1); _ = s.add(2); _ = s.add(5, to: "2")
        _ = s.park([5], because: .minimized)
        _ = s.adopt(1)
        _ = s.perform(.fullscreen)
        s.workspaces["1"]!.stamp(2)
        let plan = s.unpark([5], follow: nil)
        #expect(s.workspaces["1"]!.fullscreenWindow == nil && s.focused == 2)
        #expect(plan.frames[1] == Self.tiles()[1] && plan.frames[2] == Self.tiles()[2])
    }

    /// Measured from the frame at the press, so a window its app keeps short of the display
    /// stays in fullscreen at a jitter.
    @Test func aDragPastTheThresholdEndsItWhereTheDragLeavesIt() {
        var s = Self.session()
        let kept = Self.display.insetBy(dx: 0, dy: 40)
        #expect(s.dragged(3, to: kept.offsetBy(dx: 6, dy: 6), from: kept) == nil)
        #expect(s.workspaces["1"]!.fullscreenWindow == 3)
        #expect(s.dragged(3, to: kept.offsetBy(dx: 0, dy: 20), from: kept) == Session.Plan())
        #expect(s.workspaces["1"]!.fullscreenWindow == nil && s.perform(.fullscreen, frame: { _ in nil }) == nil)
    }

    @Test func aModifierDragEndsItPastTheThreshold() throws {
        var s = Self.session()
        let grab = DragGate.Grab(button: .left, window: 3, start: CGPoint(x: 700, y: 500))
        var drag = try #require(s.beginDrag(grab, frame: Self.display))
        let jitter = drag.delta(to: CGPoint(x: 705, y: 500)), moved = drag.delta(to: CGPoint(x: 730, y: 500))
        #expect(jitter == nil)
        let delta = try #require(moved)
        #expect(s.dragged(3, to: drag.moved(by: delta), from: drag.frame) != nil)
        #expect(s.workspaces["1"]!.fullscreenWindow == nil)
    }

    /// Dropped over the floating fullscreen window, the tile lands beside the tile under it.
    @Test func aTileDroppedOverItTilesAndEndsIt() {
        let left = Monitor(id: 1, frame: Self.display), right = Monitor(id: 2, frame: Self.display.offsetBy(dx: 1000, dy: 0))
        var s = Session(names: ["1", "2"], monitors: [left, right], assigned: ["1": 1, "2": 2])
        _ = s.add(1); _ = s.add(2)
        _ = s.add(5, to: "2"); _ = s.add(3, to: "2", floating: true)
        _ = s.follow(3)
        _ = s.perform(.fullscreen, frame: { _ in Self.own.offsetBy(dx: 1000, dy: 0) })
        _ = s.lift(1)
        let plan = s.drop(at: CGPoint(x: 1500, y: 400))
        #expect(s.workspace(of: 1) == "2" && s.workspaces["2"]!.root.windows.contains(1))
        #expect(s.workspaces["2"]!.fullscreenWindow == nil && plan.frames[3] == Self.own.offsetBy(dx: 1000, dy: 0))
    }

    // MARK: Restart

    @Test func aRestartKeepsItAndItsFrame() throws {
        var before = Session(names: ["1", "2"], display: Self.display)
        _ = before.add(1); _ = before.add(2); _ = before.add(3, floating: true); _ = before.add(4, floating: true)
        _ = before.adopt(4)
        _ = before.perform(.fullscreen, frame: { _ in CGRect(x: 600, y: 400, width: 200, height: 100) })
        _ = before.park([4], because: .minimized)
        _ = before.adopt(3)
        _ = before.perform(.fullscreen, frame: { _ in Self.own })
        let saved = try JSONDecoder().decode(SavedLayout.self, from: JSONEncoder().encode(before.savedLayout()))
        var after = Session(names: ["1", "2"], display: Self.display)
        after.restore(saved)
        for window: WindowID in [1, 2, 3] { _ = after.add(window) }
        _ = after.add(4, parked: .minimized)
        #expect(after.workspaces["1"]!.fullscreenWindow == 3 && after.frames(of: "1")[3] == Self.display)
        #expect(after.unpark([4], follow: nil).frames[4] == CGRect(x: 600, y: 400, width: 200, height: 100))
        #expect(after.perform(.fullscreen, frame: { _ in nil })?.frames[3] == Self.own)
    }

    /// A file from before floating frames were saved has none, and one with no area loses it.
    @Test func aSavedFloatingWindowWithNoSoundFrameComesBackOutOfFullscreen() throws {
        var entry = SavedLayout.Window(window: 3, workspace: "1", floating: true, parked: false, fullscreen: true,
                                       frameBeforeFullscreen: CGRect(x: 0, y: 0, width: 0, height: 300), stamp: 1, stale: false)
        #expect(entry.pending(edits: 0)?.frameBeforeFullscreen == nil)
        entry.frameBeforeFullscreen = nil
        let json = String(data: try JSONEncoder().encode(entry), encoding: .utf8)!
        #expect(!json.contains("frameBeforeFullscreen"))
        var s = Session(names: ["1"], display: Self.display)
        s.restore(SavedLayout(shown: [], focusedWorkspace: "1", focusedWindow: 3, windows: [entry]))
        _ = s.add(3)
        #expect(s.isFloating(3) && s.workspaces["1"]!.fullscreenWindow == nil)
    }
}
