import Testing
@testable import KosmosCore

@Test func aTargetFocusedInTheFrontAppIsKeyAlready() {
    #expect(!KeyWindow.window(1).goesAhead(appIsFront: true, focused: .some(1)))
    #expect(KeyWindow.window(1).goesAhead(appIsFront: true, focused: .some(2)))
    #expect(KeyWindow.window(1).goesAhead(appIsFront: true, focused: .some(nil)))
}

@Test func aRequestForAnAppBehindTheFrontGoesAheadUnread() {
    // Its app still names the window as focused, but macOS keys the front app's window.
    #expect(KeyWindow.window(1).goesAhead(appIsFront: false, focused: .some(1)))
    #expect(KeyWindow.window(1).goesAhead(appIsFront: false, focused: nil))
}

@Test func aReadWithNoAnswerStopsTheRequest() {
    #expect(!KeyWindow.window(1).goesAhead(appIsFront: true, focused: nil))
    #expect(!KeyWindow.none.goesAhead(appIsFront: true, focused: nil))
}

@Test func anEmptyWorkspaceIsKeyWhenFinderIsFrontWithNoWindowFocused() {
    #expect(!KeyWindow.none.goesAhead(appIsFront: true, focused: .some(nil)))
    #expect(KeyWindow.none.goesAhead(appIsFront: true, focused: .some(3)))
    #expect(KeyWindow.none.goesAhead(appIsFront: false, focused: .some(nil)))
}
