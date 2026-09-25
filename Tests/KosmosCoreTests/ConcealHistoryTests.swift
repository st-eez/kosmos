import Testing
@testable import KosmosCore

@Test func aCommandTabBeforeTheRevealWasToAHiddenWindow() {
    var history = ConcealHistory<Int>()
    history.changed([3], concealed: true, at: 10)
    history.changed([3], concealed: false, at: 30)
    // Command-Tab at 20; the switch to window 3's workspace revealed it at 30.
    #expect(history.wasConcealed(3, at: 20, now: false))
    #expect(!history.wasConcealed(3, at: 30, now: false))
}

@Test func aClickBeforeTheConcealWasOnAVisibleWindow() {
    var history = ConcealHistory<Int>()
    history.changed([3], concealed: true, at: 30)
    #expect(!history.wasConcealed(3, at: 20, now: true))
    #expect(history.wasConcealed(3, at: 40, now: true))
}

@Test func aWindowWithNoChangeIsAsItIsNow() {
    var history = ConcealHistory<Int>()
    #expect(history.wasConcealed(3, at: 20, now: true))
    #expect(!history.wasConcealed(3, at: 20, now: false))
    history.changed([3], concealed: true, at: 10)
    history.forgetAll()
    #expect(!history.wasConcealed(3, at: 20, now: false))
}
