import Testing
@testable import KosmosCore

private func changes(_ signals: [LockState.Signal]) -> [LockState.Change?] {
    var state = LockState()
    return signals.map { state.apply($0) }
}

@Test func lockAndUnlockEachChangeOnce() {
    #expect(changes([.screenLocked, .screenLocked, .screenUnlocked, .screenUnlocked])
        == [.locked, nil, .unlocked, nil])
}

@Test func anUnlockWhileSwitchedOutStaysLocked() {
    // The screen can lock while the session is switched out.
    #expect(changes([.switchedOut, .screenLocked, .screenUnlocked, .switchedIn])
        == [.locked, nil, nil, .unlocked])
    #expect(changes([.switchedOut, .screenLocked, .switchedIn, .screenUnlocked])
        == [.locked, nil, nil, .unlocked])
}

@Test func aReadCatchesAMissedUnlock() {
    #expect(changes([.screenLocked, .read(screenLocked: true, onConsole: true), .read(screenLocked: false, onConsole: true)])
        == [.locked, nil, .unlocked])
    #expect(changes([.switchedOut, .read(screenLocked: false, onConsole: true)]) == [.locked, .unlocked])
}

@Test func aReadAtLaunchFindsTheLock() {
    #expect(changes([.read(screenLocked: false, onConsole: true)]) == [nil])
    #expect(changes([.read(screenLocked: true, onConsole: true)]) == [.locked])
    #expect(changes([.read(screenLocked: false, onConsole: false)]) == [.locked])
}
