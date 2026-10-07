import CoreGraphics
import Testing
@testable import KosmosCore

private let A: WindowID = 1, B: WindowID = 2, C: WindowID = 3, F: WindowID = 4, X: WindowID = 20

/// Steve's scenarios of 2026-10-02 (docs/tree.md): A in fullscreen on display D over tiles B
/// and C, floating window F on D, and X on display D2 to the right. Each test is the part
/// Kosmos decides; what macOS stacks at a click or an activation is macOS's.
@Suite struct FullscreenFocusTests {
    static let d = Monitor(id: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 800))
    static let d2 = Monitor(id: 2, frame: CGRect(x: 1000, y: 0, width: 1000, height: 800))
    /// F's frames. A's center is D's, (500, 400).
    static let leftHalf = CGRect(x: 100, y: 300, width: 200, height: 200)
    static let rightHalf = CGRect(x: 700, y: 300, width: 200, height: 200)
    static let centered = CGRect(x: 400, y: 300, width: 200, height: 200)

    /// A focused in fullscreen. F has no frame until a test gives one.
    static func session() -> Session {
        var s = Session(names: ["1", "2", "3"], monitors: [d, d2], assigned: ["1": 1, "2": 2, "3": 1])
        _ = s.add(A); _ = s.add(B); _ = s.add(C); _ = s.add(F, floating: true); _ = s.add(X, to: "2")
        _ = s.adopt(A)
        _ = s.perform(.fullscreen)
        #expect(s.workspaces["1"]!.fullscreenWindow == A)
        return s
    }

    static func at(_ f: CGRect) -> (WindowID) -> CGRect? { { $0 == F ? f : nil } }

    static func arrow(_ s: inout Session, _ direction: Direction, f: CGRect) -> KeyWindow? {
        s.perform(.focus(direction, boundaries: .allMonitors), frame: at(f))?.focus
    }

    /// 1. A takes the keyboard without coming forward, so F stays on top. B and C are never
    /// candidates, from F either.
    @Test func fromFTowardA() {
        var s = Self.session()
        _ = s.adopt(F)
        #expect(Self.arrow(&s, .down, f: Self.rightHalf) == nil)
        #expect(s.focused == F)
        #expect(Self.arrow(&s, .left, f: Self.rightHalf) == .window(A))
        #expect(s.workspaces["1"]!.fullscreenWindow == A)
        #expect(s.floatingOverlaps(A, frame: Self.at(Self.rightHalf)))
    }

    /// 2. F takes the focus and comes up, as any floating window does.
    @Test func fromATowardF() {
        var s = Self.session()
        #expect(Self.arrow(&s, .right, f: Self.rightHalf) == .window(F))
        #expect(!s.floatingOverlaps(F, frame: Self.at(Self.rightHalf)))
        #expect(s.workspaces["1"]!.fullscreenWindow == A)
    }

    /// 3.
    @Test func fromAWithNoFloatingWindowThatWayToTheNextDisplay() {
        var s = Self.session()
        #expect(Self.arrow(&s, .right, f: Self.leftHalf) == .window(X))
        #expect(s.focusedWorkspace == "2" && s.workspaces["1"]!.fullscreenWindow == A)
    }

    /// 4. F level with A's center is neither above nor below it.
    @Test func fromAWithNoDisplayThatWayNothingHappens() {
        var s = Self.session()
        for direction in [Direction.left, .up, .down] {
            #expect(Self.arrow(&s, direction, f: Self.rightHalf) == nil)
        }
        #expect(s.perform(.focus(.right), frame: Self.at(Self.leftHalf)) == nil)
        #expect(s.focused == A && s.workspaces["1"]!.fullscreenWindow == A)
    }

    /// 5. The pointer's window is WindowServer's hit test; Kosmos adopts A and keys it without
    /// a raise.
    @Test func hoverOverAOutsideF() {
        var s = Self.session()
        _ = s.adopt(F)
        var hover = FocusFollowsMouse()
        hover.enabled = true
        #expect(hover.skip(A, in: s, fullscreen: false, key: .window(F), app: nil, stale: false) == nil)
        #expect(s.adopt(A).isEmpty)
        #expect(s.focused == A && s.floatingOverlaps(A, frame: Self.at(Self.leftHalf)))
    }

    /// 6. macOS brings A over F at the click. F stays a candidate, and its focus raises it.
    @Test func afterAClickOnAnArrowStillReachesF() {
        var s = Self.session()
        _ = s.adopt(F)
        #expect(s.adopt(A).isEmpty)
        #expect(Self.arrow(&s, .right, f: Self.rightHalf) == .window(F))
        #expect(!s.floatingOverlaps(F, frame: Self.at(Self.rightHalf)))
    }

    /// 7.
    @Test func switchingAwayAndBack() {
        var s = Self.session()
        _ = s.perform(.workspace(.named("3")))
        let back = s.perform(.workspace(.named("1")))
        #expect(back?.focus == .window(A) && back?.show.contains(F) == true)
        #expect(s.workspaces["1"]!.fullscreenWindow == A)
        #expect(s.floatingOverlaps(A, frame: Self.at(Self.leftHalf)))
    }

    /// 8. Command-Tab or a click keys B, and Kosmos adopts it.
    @Test func focusOnBEndsFullscreen() {
        var s = Self.session()
        let plan = s.adopt(B)
        #expect(s.workspaces["1"]!.fullscreenWindow == nil && s.focused == B)
        #expect(plan.frames == s.frames(of: "1") && plan.frames.count == 3)
    }

    /// 9. macOS brings F forward as its app activates; Kosmos keeps A in fullscreen.
    @Test func commandTabToFsApp() {
        var s = Self.session()
        #expect(s.adopt(F).isEmpty)
        #expect(s.focused == F && s.workspaces["1"]!.fullscreenWindow == A)
    }

    /// 10. The command asks for no focus, so nothing raises A over F.
    @Test func togglingFullscreenOff() {
        var s = Self.session()
        let plan = s.perform(.fullscreen)
        #expect(plan?.focus == nil && plan?.frames == s.frames(of: "1") && plan?.frames.count == 3)
        #expect(s.workspaces["1"]!.fullscreenWindow == nil)
    }

    /// 11. macOS opens a dialog on top, and Kosmos manages none. A new window a rule floats,
    /// keyed as it opens, leaves A in fullscreen.
    @Test func aNewFloatingWindowKeyedKeepsFullscreen() {
        var s = Self.session()
        _ = s.add(5, floating: true)
        #expect(s.adopt(5).isEmpty)
        #expect(s.workspaces["1"]!.fullscreenWindow == A)
    }

    /// 12. F centered with A lies right of it and below it.
    @Test func fCenteredWithA() {
        var s = Self.session()
        #expect(Self.arrow(&s, .right, f: Self.centered) == .window(F))
        #expect(Self.arrow(&s, .left, f: Self.centered) == .window(A))
        #expect(Self.arrow(&s, .down, f: Self.centered) == .window(F))
        #expect(Self.arrow(&s, .up, f: Self.centered) == .window(A))
        #expect(Self.arrow(&s, .left, f: Self.centered) == nil)
        #expect(Self.arrow(&s, .up, f: Self.centered) == nil)
        _ = s.adopt(F)
        #expect(Self.arrow(&s, .right, f: Self.centered) == .window(X))
        #expect(s.workspaces["1"]!.fullscreenWindow == A)
    }

    /// 13. From X the focus enters D by its right edge, where it meets D2.
    @Test func arrivingFromX() {
        for (f, lands) in [(Self.rightHalf, F), (Self.leftHalf, A), (Self.centered, F)] {
            var s = Self.session()
            _ = s.adopt(X)
            #expect(Self.arrow(&s, .left, f: f) == .window(lands))
            #expect(s.workspaces["1"]!.fullscreenWindow == A)
        }
    }

    /// Steve's loop check: with F on the right half, right goes A to F to X, and left from F
    /// goes back to A.
    @Test func pressesOneWayNeverComeBack() {
        var s = Self.session()
        #expect(Self.arrow(&s, .right, f: Self.rightHalf) == .window(F))
        #expect(Self.arrow(&s, .right, f: Self.rightHalf) == .window(X))
        _ = s.adopt(F)
        #expect(Self.arrow(&s, .left, f: Self.rightHalf) == .window(A))
    }

    /// `layout floating tiling` on F, focused, tiles it and ends A's fullscreen.
    @Test func tilingTheFocusedFloatingWindowUnderAFullscreenOneKeepsTheArrowsWorking() {
        var s = Self.session()
        _ = s.adopt(F)
        let plan = s.perform(.layout(.toggleFloating))
        #expect(!s.isFloating(F))
        let fullscreen = s.workspaces["1"]!.fullscreenWindow
        #expect(fullscreen == nil || s.focused == fullscreen)
        #expect(plan?.frames == s.frames(of: "1"))
        let moves = [Direction.left, .right, .up, .down].compactMap { d in var c = s; return c.perform(.focus(d))?.focus }
        #expect(!moves.isEmpty)
    }
}
