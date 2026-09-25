import Testing
@testable import KosmosCore

private let t0 = ContinuousClock.now

@Test func aChangeIsJudgedByThePressOnWhenItCame() {
    var button = LeftButton()
    #expect(button.state(at: t0) == .up)
    button.pressed(at: t0 + .milliseconds(10))
    #expect(button.state(at: t0 + .milliseconds(5)) == .up)
    #expect(button.state(at: t0 + .milliseconds(20)) == .down)
    // The change came during the press and applies after its mouse up.
    button.released(at: t0 + .milliseconds(30))
    #expect(button.state(at: t0 + .milliseconds(20)) == .released)
    #expect(button.state(at: t0 + .milliseconds(30)) == .up)
    // A press that began after the change came leaves it to the one before.
    button.pressed(at: t0 + .milliseconds(40))
    #expect(button.state(at: t0 + .milliseconds(20)) == .released)
    #expect(button.state(at: t0 + .milliseconds(35)) == .up)
}
