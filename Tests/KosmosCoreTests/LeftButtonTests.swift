import Testing
@testable import KosmosCore

@Test func aChangeIsJudgedByThePressOnWhenItCame() {
    var button = LeftButton()
    #expect(button.state(at: t0) == .up)
    button.pressed(at: t0 + .milliseconds(10))
    #expect(button.state(at: t0 + .milliseconds(5)) == .up)
    #expect(button.state(at: t0 + .milliseconds(20)) == .down)
    button.released(at: t0 + .milliseconds(30))
    #expect(button.state(at: t0 + .milliseconds(20)) == .released)
    #expect(button.state(at: t0 + .milliseconds(30)) == .up)
    button.pressed(at: t0 + .milliseconds(40))
    #expect(button.state(at: t0 + .milliseconds(20)) == .released)
    #expect(button.state(at: t0 + .milliseconds(35)) == .up)
}
