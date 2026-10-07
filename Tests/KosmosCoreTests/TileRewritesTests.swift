import CoreGraphics
import Testing
@testable import KosmosCore

private let tile = CGRect(x: 10, y: 35, width: 945, height: 1035)
/// Alarm.com's web app shrank its own window to 480 wide (docs/geometry.md).
private let narrow = CGRect(x: 10, y: 35, width: 480, height: 1035)

@Test func aTiledWindowSeenSmallerThanItsTileIsWrittenAgain() {
    var rewrites = TileRewrites()
    #expect(rewrites.judge(1, seen: narrow, tile: tile, busy: false, at: t0) == .rewrite(1))
    #expect(rewrites.judge(1, seen: CGRect(x: 10, y: 35, width: 945, height: 1000), tile: tile, busy: false, at: t0) == .rewrite(2))
}

@Test func aWindowAtLargerOrWithinTheSlackOfItsTileIsLeft() {
    var rewrites = TileRewrites()
    #expect(rewrites.judge(1, seen: tile, tile: tile, busy: false, at: t0) == .none)
    #expect(rewrites.judge(1, seen: CGRect(x: 10, y: 35, width: 943, height: 1033), tile: tile, busy: false, at: t0) == .none)
    #expect(rewrites.judge(1, seen: CGRect(x: 10, y: 35, width: 1900, height: 1035), tile: tile, busy: false, at: t0) == .none)
    #expect(rewrites.judge(1, seen: CGRect(x: 500, y: 35, width: 945, height: 1035), tile: tile, busy: false, at: t0) == .none)
}

/// A floating, parked or hidden window has no tile; one written to, pressed or dragged is busy.
@Test func aWindowWithNoTileOrBusyIsLeft() {
    var rewrites = TileRewrites()
    #expect(rewrites.judge(1, seen: narrow, tile: nil, busy: false, at: t0) == .none)
    #expect(rewrites.judge(1, seen: narrow, tile: tile, busy: true, at: t0) == .none)
    #expect(rewrites.judge(1, seen: narrow, tile: tile, busy: false, at: t0) == .rewrite(1))
}

@Test func theFourthRewriteIn5sGivesUpOnceUntilTheTileChanges() {
    var rewrites = TileRewrites()
    for count in 1...TileRewrites.limit {
        #expect(rewrites.judge(1, seen: narrow, tile: tile, busy: false, at: t0 + .seconds(count)) == .rewrite(count))
    }
    #expect(rewrites.judge(1, seen: narrow, tile: tile, busy: false, at: t0 + .seconds(4)) == .gaveUp)
    #expect(rewrites.judge(1, seen: narrow, tile: tile, busy: false, at: t0 + .seconds(60)) == .none)
    // Another window keeps its own count.
    #expect(rewrites.judge(2, seen: narrow, tile: tile, busy: false, at: t0 + .seconds(4)) == .rewrite(1))
    let other = tile.offsetBy(dx: 0, dy: 10)
    #expect(rewrites.judge(1, seen: narrow, tile: other, busy: false, at: t0 + .seconds(61)) == .rewrite(1))
    rewrites.forget(2)
    #expect(rewrites.judge(2, seen: narrow, tile: tile, busy: false, at: t0 + .seconds(4)) == .rewrite(1))
}

@Test func rewritesMoreThan5sApartNeverGiveUp() {
    var rewrites = TileRewrites()
    for step in 0..<6 {
        let decision = rewrites.judge(1, seen: narrow, tile: tile, busy: false, at: t0 + .seconds(3 * step))
        #expect(decision == .rewrite(step < 2 ? step + 1 : 2))
    }
}

@Test func aRewritesReadBackTellsWhenTheWindowWasFirstSeenSmaller() {
    var rewrites = TileRewrites()
    let shrank = t0 - .milliseconds(5)
    #expect(rewrites.readBack(1, narrow, target: tile) == nil)
    _ = rewrites.judge(1, seen: narrow, tile: tile, busy: false, at: t0, since: shrank)
    #expect(rewrites.readBack(1, narrow, target: tile.offsetBy(dx: 1, dy: 0)) == nil)
    #expect(rewrites.readBack(1, narrow, target: tile) == shrank)
    _ = rewrites.judge(1, seen: narrow, tile: tile, busy: false, at: t0 + .milliseconds(20))
    #expect(rewrites.readBack(1, tile, target: tile) == shrank)
    #expect(rewrites.readBack(1, tile, target: tile) == nil)
}
