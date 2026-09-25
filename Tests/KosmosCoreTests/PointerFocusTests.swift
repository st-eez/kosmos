import CoreGraphics
import Testing
@testable import KosmosCore

/// Runs movements through one gate, each the window under the pointer and whether Control
/// is held, and returns which ones go on to the main actor.
private func admitted(_ movements: [(window: UInt32, control: Bool)], gate: inout PointerGate) -> [Bool] {
    movements.map { gate.admit($0.window, control: $0.control) }
}

private func admitted(_ movements: [(window: UInt32, control: Bool)]) -> [Bool] {
    var gate = PointerGate()
    return admitted(movements, gate: &gate)
}

@Suite struct PointerGateTests {
    @Test func onlyAMovementIntoAnotherWindowGoesOn() {
        // The first movement counts wherever it is, as after focus follows mouse turns on.
        #expect(admitted([(7, false), (7, false), (8, false), (8, false), (7, false)]) == [true, false, true, false, true])
    }

    @Test func controlPausesUntilTheNextMovementWithoutIt() {
        // Released inside window 8: the next movement enters it.
        #expect(admitted([(7, false), (8, true), (8, true), (8, false)]) == [true, false, false, true])
        // Back in the window where Control went down: nothing to enter.
        #expect(admitted([(7, false), (8, true), (7, true), (7, false)]) == [true, false, false, false])
    }

    @Test func theMovementAfterKosmosMovesThePointerEntersNothing() {
        // A command focused window 9 and moved the pointer there from window 7.
        var gate = PointerGate()
        #expect(admitted([(7, false)], gate: &gate) == [true])
        gate.warped()
        #expect(admitted([(9, false), (9, false), (7, false)], gate: &gate) == [false, false, true])
    }

    @Test func theMovementAfterTheMoveCountsWhereverThePointerLanded() {
        // The move landed over window 8, not the window Kosmos focused: focus stays.
        var gate = PointerGate()
        #expect(admitted([(7, false)], gate: &gate) == [true])
        gate.warped()
        #expect(admitted([(8, false), (8, false), (9, false)], gate: &gate) == [false, false, true])
    }

    @Test func theMovementAfterAMoveWithControlHeldEntersNothingEither() {
        var gate = PointerGate()
        #expect(admitted([(7, false)], gate: &gate) == [true])
        gate.warped()
        #expect(admitted([(9, true), (9, false), (7, false)], gate: &gate) == [false, false, true])
    }
}

private func session() -> Session {
    var s = Session(names: ["1", "2"], display: CGRect(x: 0, y: 0, width: 1000, height: 800))
    _ = s.add(1)
    _ = s.add(2)
    _ = s.float(2)
    _ = s.add(3)
    _ = s.park([3])
    _ = s.add(4, to: "2")
    s.adopt(1)
    return s
}

private func settings(enabled: Bool = true) -> FocusFollowsMouse {
    var settings = FocusFollowsMouse()
    settings.enabled = enabled
    settings.ignoreApps = ["Numi"]
    return settings
}

private func skip(_ window: WindowID, _ settings: FocusFollowsMouse = settings(), key: KeyWindow? = .window(1),
                  app: (bundleID: String?, name: String?)? = ("com.mitchellh.ghostty", "Ghostty"),
                  stale: Bool = false, fullscreenShown: Bool = false) -> PointerSkip? {
    settings.skip(window, in: session(), key: key, app: app, stale: stale, fullscreenShown: fullscreenShown)
}

@Suite struct FocusFollowsMouseTests {
    @Test func tiledAndFloatingWindowsOfTheShownWorkspaceTakeFocus() {
        #expect(skip(2) == nil)                    // floating
        #expect(skip(1, key: .window(2)) == nil)   // tiled
    }

    @Test func otherWindowsLeaveFocusAlone() {
        #expect(skip(3) == .notTiled)    // parked: minimized, hidden or in native fullscreen
        #expect(skip(4) == .notTiled)    // another workspace, which a switch may still show
        #expect(skip(99, app: nil) == .notTiled)   // a menu, the bar, or a window of Kosmos's own
    }

    @Test func theFocusedKeyWindowIsLeftAlone() {
        #expect(skip(1, key: .window(1)) == .focused)
        // Focused, but a panel or dialog is key: entering the window keys it again.
        #expect(skip(1, key: .window(50)) == nil)
        #expect(skip(1, key: KeyWindow.none) == nil)
    }

    @Test func ignoredAppsOffStaleAndFullscreen() {
        #expect(skip(2, app: ("com.numi.Numi", "Numi")) == .ignoredApp)
        #expect(skip(2, settings(enabled: false)) == .off)
        #expect(skip(2, stale: true) == .stale)
        #expect(skip(2, fullscreenShown: true) == .fullscreen)
    }

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

@Test func onlyTiledAndFloatingWindowsOfTheShownWorkspaceAreVisible() {
    let s = session()
    #expect(s.isVisible(1) && s.isVisible(2))
    #expect(!s.isVisible(3))   // parked
    #expect(!s.isVisible(4))   // another workspace
    #expect(!s.isVisible(9))   // unknown
}

@Test func focusFollowsMouseIsForTheApp() {
    var s = session()
    #expect(s.perform(.focusFollowsMouse(.toggle)) == nil)
}
