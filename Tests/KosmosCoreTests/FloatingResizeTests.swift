import CoreGraphics
import Testing
@testable import KosmosCore

/// `resize` on a floating window keeps its center and its display's area (docs/tree.md).
@Suite struct FloatingResizeTests {
    static let display = CGRect(x: 0, y: 0, width: 1000, height: 800)
    /// Below a 25 pt menu bar.
    static let area = CGRect(x: 0, y: 25, width: 1000, height: 775)
    static let own = CGRect(x: 300, y: 200, width: 400, height: 300)

    /// Tile 1, and floating 2, focused.
    static func session() -> Session {
        var s = Session(names: ["1"], monitors: [Monitor(id: 1, frame: display, area: area)])
        _ = s.add(1); _ = s.add(2, floating: true)
        _ = s.adopt(2)
        return s
    }

    @Test func smartIsTheWidthAndTheCenterStays() {
        var s = Self.session()
        #expect(s.perform(.resize(.smart, by: 100), frame: { _ in Self.own })?.frames
            == [2: CGRect(x: 250, y: 200, width: 500, height: 300)])
        #expect(s.perform(.resize(.width, by: -50), frame: { _ in Self.own })?.frames
            == [2: CGRect(x: 325, y: 200, width: 350, height: 300)])
        #expect(s.perform(.resize(.height, by: 100), frame: { _ in Self.own })?.frames
            == [2: CGRect(x: 300, y: 150, width: 400, height: 400)])
    }

    @Test func itStaysInTheArea() {
        var s = Self.session()
        let corner = CGRect(x: 0, y: 25, width: 400, height: 300)
        #expect(s.perform(.resize(.width, by: 100), frame: { _ in corner })?.frames[2]
            == CGRect(x: 0, y: 25, width: 500, height: 300))
        #expect(s.perform(.resize(.height, by: 100), frame: { _ in corner })?.frames[2]
            == CGRect(x: 0, y: 25, width: 400, height: 400))
        #expect(s.perform(.resize(.smart, by: 100), frame: { _ in CGRect(x: 20, y: 100, width: 950, height: 300) })?.frames[2]
            == CGRect(x: 0, y: 100, width: 1000, height: 300))
        #expect(s.perform(.resize(.smart, by: 100), frame: { _ in CGRect(x: 0, y: 100, width: 1000, height: 300) }) == nil)
    }

    @Test func itStopsAtItsMinimum() {
        var s = Self.session()
        _ = s.constrain(2, to: CGSize(width: 350, height: 0))
        #expect(s.perform(.resize(.smart, by: -100), frame: { _ in Self.own })?.frames[2]
            == CGRect(x: 325, y: 200, width: 350, height: 300))
        #expect(s.perform(.resize(.smart, by: -100), frame: { _ in CGRect(x: 325, y: 200, width: 350, height: 300) }) == nil)
        // With no minimum on the axis, `ModifierDrag.smallestSide`.
        #expect(s.perform(.resize(.height, by: -1000), frame: { _ in Self.own })?.frames[2]
            == CGRect(x: 300, y: 340, width: 400, height: 20))
    }

    @Test func aFullscreenWindowIsLeftAlone() {
        var s = Self.session()
        _ = s.perform(.fullscreen, frame: { _ in Self.own })
        #expect(s.perform(.resize(.smart, by: 100), frame: { _ in Self.area }) == nil)
        #expect(s.perform(.fullscreen)?.frames[2] == Self.own)
    }
}
