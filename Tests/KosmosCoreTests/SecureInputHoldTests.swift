import Testing
@testable import KosmosCore

@Test func aBriefHoldShowsNothing() {
    var hold = SecureInputHold<String>()
    hold.update("Ghostty", at: t0)
    #expect(hold.shown(at: t0 + .milliseconds(35)) == nil)
    hold.update(nil, at: t0 + .milliseconds(35))
    // The wait scheduled at the start finds the hold over.
    #expect(hold.shown(at: t0 + .milliseconds(500)) == nil)
    #expect(hold.due == nil)
}

@Test func aHoldShowsOnceItHasLastedTheDelay() {
    var hold = SecureInputHold<String>()
    hold.update("Ghostty", at: t0)
    #expect(hold.due == t0 + .milliseconds(500))
    #expect(hold.shown(at: t0 + .milliseconds(499)) == nil)
    #expect(hold.shown(at: t0 + .milliseconds(500)) == "Ghostty")
    hold.update(nil, at: t0 + .milliseconds(8_400))
    #expect(hold.shown(at: t0 + .milliseconds(8_400)) == nil)
}

@Test func aNewHolderKeepsTheHoldGoing() {
    var hold = SecureInputHold<String>()
    hold.update("Ghostty", at: t0)
    hold.update("1Password", at: t0 + .milliseconds(300))
    #expect(hold.shown(at: t0 + .milliseconds(500)) == "1Password")
    hold.update("Safari", at: t0 + .milliseconds(900))
    #expect(hold.shown(at: t0 + .milliseconds(900)) == "Safari")
}

@Test func aHoldAfterABriefOneWaitsItsOwnDelay() {
    var hold = SecureInputHold<String>()
    hold.update("Ghostty", at: t0)
    hold.update(nil, at: t0 + .milliseconds(35))
    hold.update("Ghostty", at: t0 + .milliseconds(400))
    #expect(hold.shown(at: t0 + .milliseconds(500)) == nil)
    #expect(hold.shown(at: t0 + .milliseconds(900)) == "Ghostty")
}
