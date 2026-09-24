import CoreGraphics
import Testing
@testable import KosmosCore

/// Runs movements through one gate: each is a point, the window under it, and whether the
/// pause key is held. Returns which ones the gate admits.
private func admitted(_ movements: [(x: CGFloat, y: CGFloat, window: UInt32, paused: Bool)]) -> [Bool] {
    var gate = PointerGate()
    return movements.map { gate.admit(CGPoint(x: $0.x, y: $0.y), over: $0.window, paused: $0.paused) }
}

@Suite struct PointerGateTests {
    @Test func movementIntoAnotherWindowCounts() {
        #expect(admitted([(100, 100, 7, false), (200, 100, 7, false), (300, 100, 8, false), (200, 100, 7, false)])
            == [true, false, true, true])
    }

    @Test func movementUnderTwoPointsDoesNotCount() {
        // Into another window, but 1.5 points from where the pointer last counted; small
        // steps add up, and 2 points from there counts.
        #expect(admitted([(100, 100, 7, false), (101.5, 100, 8, false), (101, 101.8, 8, false)]) == [true, false, true])
    }

    @Test func pauseKeyHoldsFocusUntilTheNextMovement() {
        // Released inside window 8: the next movement enters it.
        #expect(admitted([(100, 100, 7, false), (300, 100, 8, true), (310, 100, 8, true), (320, 100, 8, false)])
            == [true, false, false, true])
    }

    @Test func pausedMovementStillMovesTheAnchor() {
        // One point from where the paused movement left the pointer.
        #expect(admitted([(100, 100, 7, false), (300, 100, 8, true), (301, 100, 8, false)]) == [true, false, false])
    }
}

@Suite struct FocusFollowsMouseTests {
    @Test func ignoresAppsByBundleIdentifierOrName() {
        var settings = FocusFollowsMouse()
        settings.ignoreApps = ["com.google.chrome.for.testing", "Numi"]
        #expect(settings.ignores(appID: "com.google.chrome.for.testing", appName: "Google Chrome for Testing"))
        #expect(settings.ignores(appID: nil, appName: "numi"))
        #expect(settings.ignores(appID: "COM.GOOGLE.CHROME.FOR.TESTING", appName: nil))
        // Names match whole, unlike window rules' app-name.
        #expect(!settings.ignores(appID: "com.numi.pro", appName: "Numi Pro"))
        #expect(!settings.ignores(appID: nil, appName: nil))
    }
}
