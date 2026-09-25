import Testing
@testable import KosmosCore

@Test func aTargetFocusedInTheFrontAppIsKeyAlready() {
    #expect(!focusGoesAhead(to: 1, appIsFront: true, focused: .some(1)))
    #expect(focusGoesAhead(to: 1, appIsFront: true, focused: .some(2)))
    #expect(focusGoesAhead(to: 1, appIsFront: true, focused: .some(nil)))
}

@Test func aRequestForAnAppBehindTheFrontGoesAheadUnread() {
    // Its app still names the window as focused, but macOS keys the front app's window.
    #expect(focusGoesAhead(to: 1, appIsFront: false, focused: .some(1)))
    #expect(focusGoesAhead(to: 1, appIsFront: false, focused: nil))
}

@Test func aReadWithNoAnswerStopsTheRequest() {
    #expect(!focusGoesAhead(to: 1, appIsFront: true, focused: nil))
}
