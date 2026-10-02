import CoreGraphics
import Testing
@testable import KosmosCore

/// A focus keys a tile a shown floating window overlaps without bringing it forward, so the
/// floating window stays on top (docs/focus.md).
@Test func aShownFloatingWindowOverlapsATile() {
    var s = Desk.session()
    _ = s.add(10); _ = s.add(11); _ = s.add(12, floating: true)
    _ = s.add(20, to: "5"); _ = s.add(21, to: "5", floating: true)
    let tiles = s.frames(of: "1")
    var frames: [WindowID: CGRect] = [12: tiles[10]!.insetBy(dx: 100, dy: 100), 21: s.frames(of: "5")[20]!]
    #expect(s.floatingOverlaps(10) { frames[$0] })
    #expect(!s.floatingOverlaps(11) { frames[$0] })
    // On the left panel, which shows workspace 5.
    #expect(s.floatingOverlaps(20) { frames[$0] })
    // A floating window itself comes up as before.
    #expect(!s.floatingOverlaps(12) { frames[$0] })
    // One that touches the tile's edge overlaps nothing, nor does one with no frame known.
    frames[12] = CGRect(x: tiles[11]!.minX - 300, y: tiles[11]!.minY, width: 300, height: 200)
    #expect(!s.floatingOverlaps(11) { frames[$0] })
    #expect(!s.floatingOverlaps(10) { _ in nil })
    // A floating window of another shown workspace counts where it stands.
    frames[21] = tiles[11]
    #expect(s.floatingOverlaps(11) { frames[$0] })

    _ = s.perform(.workspace(.named("2")))
    _ = s.add(30)
    // A tile of a hidden workspace has nothing over it.
    #expect(!s.floatingOverlaps(10) { [12: tiles[10]!, 21: tiles[10]!][$0] })
    // A floating window of a hidden workspace overlaps nothing.
    let tile = s.frames(of: "2")[30]!
    #expect(!s.floatingOverlaps(30) { [12: tile][$0] })
}
