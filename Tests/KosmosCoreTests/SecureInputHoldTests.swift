import Testing
@testable import KosmosCore

@Test func aBriefHoldShowsNothing() {
    var hold = SecureInputHold()
    hold.update(on: true, at: t0)
    #expect(!hold.shows(at: t0 + .milliseconds(35)))
    hold.update(on: false, at: t0 + .milliseconds(35))
    // The wait scheduled at the start finds the hold over.
    #expect(!hold.shows(at: t0 + .milliseconds(500)))
    #expect(hold.due == nil)
}

@Test func aHoldShowsOnceItHasLastedTheDelay() {
    var hold = SecureInputHold()
    hold.update(on: true, at: t0)
    #expect(hold.due == t0 + .milliseconds(500))
    #expect(!hold.shows(at: t0 + .milliseconds(499)))
    #expect(hold.shows(at: t0 + .milliseconds(500)))
    hold.update(on: false, at: t0 + .milliseconds(8_400))
    #expect(!hold.shows(at: t0 + .milliseconds(8_400)))
}

@Test func aNewHolderKeepsTheHoldGoing() {
    var hold = SecureInputHold()
    hold.update(on: true, at: t0)
    hold.update(on: true, at: t0 + .milliseconds(300))
    #expect(hold.shows(at: t0 + .milliseconds(500)))
}

@Test func aHoldAfterABriefOneWaitsItsOwnDelay() {
    var hold = SecureInputHold()
    hold.update(on: true, at: t0)
    hold.update(on: false, at: t0 + .milliseconds(35))
    hold.update(on: true, at: t0 + .milliseconds(400))
    #expect(!hold.shows(at: t0 + .milliseconds(500)))
    #expect(hold.shows(at: t0 + .milliseconds(900)))
}
