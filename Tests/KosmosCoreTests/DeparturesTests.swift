import Testing
@testable import KosmosCore

@Test func aHideCountsBeforeWindowServerOrdersTheWindowOut() {
    var log = DepartureLog(bound: .seconds(1))
    log.left(7, at: t0)
    // WindowServer still reads a hidden app's window ordered in.
    log.ordered(7, in: true, was: true, at: t0 + .milliseconds(5))
    #expect(log.justLeft(7, at: t0 + .milliseconds(10)) == true)
    log.ordered(7, in: false, was: true, at: t0 + .milliseconds(17))
    #expect(log.justLeft(7, at: t0 + .milliseconds(20)) == true)
}

@Test func aWindowIsBackOnlyWhenOrderedInAgainOrRestored() {
    var log = DepartureLog(bound: .seconds(1))
    log.left(7, at: t0)
    log.ordered(7, in: true, was: false, at: t0 + .milliseconds(300))
    #expect(log.justLeft(7, at: t0 + .milliseconds(400)) == nil)
    log.left(8, at: t0)
    log.returned(8)
    #expect(log.justLeft(8, at: t0) == nil)
}

@Test func aDepartureCountsForTheBoundOnly() {
    var log = DepartureLog(bound: .seconds(1))
    log.left(7, at: t0)
    #expect(log.justLeft(7, at: t0 + .milliseconds(1100)) == false)
    #expect(log.justLeft(9, at: t0) == nil)
    log.left(8, at: t0 + .milliseconds(1200))   // prunes 7, past the bound
    #expect(log.justLeft(7, at: t0 + .milliseconds(1200)) == nil)
}

@Test func aDepartureOfTheFocusWaitsOnlyForAKeyReportThatIsComing() {
    let none: (WindowID) -> Bool = { _ in false }
    // The key window minimized: macOS keys another window and reports it.
    #expect(DepartureFocus.decide(focusLeft: true, key: .window(1), departing: [1], left: none) == .afterKeyReport)
    #expect(DepartureFocus.decide(focusLeft: true, key: .window(4), departing: [1], left: { $0 == 4 }) == .afterKeyReport)
    // Otherwise no report is coming.
    #expect(DepartureFocus.decide(focusLeft: true, key: .window(4), departing: [1], left: none) == .now)
    #expect(DepartureFocus.decide(focusLeft: true, key: .noWindow, departing: [1], left: none) == .now)
    #expect(DepartureFocus.decide(focusLeft: false, key: .window(1), departing: [1], left: none) == .none)
}

// The key window 1 closed and its app kept it.

private func afterClose(_ remaining: [DepartureFocus.OtherWindow], focusLeft: Bool = true) -> DepartureFocus {
    DepartureFocus.decide(focusLeft: focusLeft, key: .window(1), departing: [1], left: { $0 == 1 }, remaining: remaining)
}

@Test func aClosedKeyWindowWithNoOtherWindowOfItsAppFocusesAtOnce() {
    // The app stays front with no window, and no report comes (docs/focus.md).
    #expect(afterClose([]) == .now)
    #expect(afterClose([.init(orderedIn: false, minimized: false), .init(orderedIn: true, minimized: true)]) == .now)
    #expect(afterClose([], focusLeft: false) == .none)
}

@Test func aClosedKeyWindowWithAnotherWindowOfItsAppWaitsForTheKeyReport() {
    #expect(afterClose([.init(orderedIn: true, minimized: false)]) == .afterKeyReport)
}

@Test func aClosedKeyWindowWithAnotherWindowConcealedWaitsForTheKeyReport() {
    // A conceal leaves a window ordered in (kosmos-probe reveal), and macOS keys it
    // (docs/focus.md).
    let concealed = DepartureFocus.OtherWindow(orderedIn: true, minimized: false)
    #expect(afterClose([concealed]) == .afterKeyReport)
}
