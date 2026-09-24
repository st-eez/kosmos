import Testing
@testable import KosmosCore

@Test func theFrontAppsFocusedWindowIsAlreadyKey() {
    #expect(KeyWindow.window(1).isAlreadyKey(appIsFront: true, focused: .some(1)))
    #expect(!KeyWindow.window(1).isAlreadyKey(appIsFront: true, focused: .some(2)))
    #expect(!KeyWindow.window(1).isAlreadyKey(appIsFront: true, focused: .some(nil)))
}

@Test func aWindowOfAnAppBehindTheFrontIsNotKey() {
    // Its app still names it as focused, but macOS keys the front app's window.
    #expect(!KeyWindow.window(1).isAlreadyKey(appIsFront: false, focused: .some(1)))
}

@Test func anUnansweredReadLetsTheRequestGoAhead() {
    #expect(!KeyWindow.window(1).isAlreadyKey(appIsFront: true, focused: nil))
    #expect(!KeyWindow.none.isAlreadyKey(appIsFront: true, focused: nil))
}

@Test func anEmptyWorkspaceIsKeyWhenFinderIsFrontWithNoWindowKey() {
    #expect(KeyWindow.none.isAlreadyKey(appIsFront: true, focused: .some(nil)))
    #expect(!KeyWindow.none.isAlreadyKey(appIsFront: true, focused: .some(3)))
    #expect(!KeyWindow.none.isAlreadyKey(appIsFront: false, focused: .some(nil)))
}
