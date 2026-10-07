import CoreGraphics
import Testing
@testable import KosmosCore

/// IINA's Video > Float on Top raises its window off level 0 while it is open.
struct LeveledTests {
    static func session() -> Session {
        var s = Session(names: ["1", "2"], display: CGRect(x: 0, y: 0, width: 1000, height: 800))
        _ = s.add(1)
        _ = s.add(2)
        return s
    }

    @Test func aRaisedTileFloatsWhereItIsAndTheOthersFillItsSpace() throws {
        var s = Self.session()
        let raised = s.leveled(2, raised: true)
        let plan = try #require(raised)
        #expect(s.isFloating(2) && s.workspace(of: 2) == "1")
        #expect(plan.frames[2] == nil)
        #expect(plan.frames[1] == s.frames(of: "1")[1])
        #expect(s.workspaces["1"]!.root.windows == [1])
    }

    @Test func itStillHidesWithItsWorkspace() {
        var s = Self.session()
        _ = s.leveled(2, raised: true)
        let away = s.perform(.workspace(.named("2")))
        let back = s.perform(.workspace(.named("1")))
        #expect(away?.hide.contains(2) == true)
        #expect(back?.show.contains(2) == true)
    }

    @Test func backAtLevelZeroItTilesWhereItWas() throws {
        var s = Self.session()
        let before = s.frames(of: "1")
        _ = s.leveled(2, raised: true)
        let back = s.leveled(2, raised: false)
        let plan = try #require(back)
        #expect(!s.isFloating(2) && s.floatedForLevel.isEmpty)
        #expect(plan.frames == before)
    }

    @Test func aWindowFloatingForAnotherReasonIsNeverTiledByItsLevel() {
        var s = Self.session()
        _ = s.add(3, floating: true)
        let raised = s.leveled(3, raised: true), back = s.leveled(3, raised: false)
        #expect(raised == nil && back == nil)
        #expect(s.isFloating(3))
    }

    @Test func theUsersToggleWinsOverTheLevelsReturn() {
        var s = Session(names: ["1"], display: CGRect(x: 0, y: 0, width: 1000, height: 800))
        _ = s.add(2)   // focused, as the first window
        _ = s.add(1)
        _ = s.leveled(2, raised: true)
        _ = s.perform(.layout(.toggleFloating))
        #expect(!s.isFloating(2) && s.floatedForLevel.isEmpty)
        _ = s.perform(.layout(.toggleFloating))
        let back = s.leveled(2, raised: false)
        #expect(back == nil)
        #expect(s.isFloating(2))
    }

    @Test func aTabSwitchPassesItOnAndACloseForgetsIt() {
        var s = Self.session()
        _ = s.leveled(2, raised: true)
        _ = s.replace(2, with: 9)
        #expect(s.floatedForLevel == [9])
        _ = s.remove(9)
        #expect(s.floatedForLevel.isEmpty)
    }

    @Test func anUnknownWindowChangesNothing() {
        var s = Self.session()
        let raised = s.leveled(7, raised: true), back = s.leveled(7, raised: false)
        #expect(raised == nil && back == nil)
    }
}
