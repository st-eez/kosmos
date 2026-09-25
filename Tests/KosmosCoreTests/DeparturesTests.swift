import Testing
@testable import KosmosCore

// The pieces that fixed the live Command-H re-key (tla/README.md, change 11).

@Test func aHideCountsBeforeWindowServerOrdersTheWindowOut() {
    var log = DepartureLog(bound: .seconds(1))
    log.left(7, at: t0)   // NSWorkspace reported the app hidden
    // WindowServer still reads the window ordered in; only a change of order counts.
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
    log.left(8, at: t0)   // minimized
    log.returned(8)       // restored
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
    // The key window left in an event not handled yet.
    #expect(DepartureFocus.decide(focusLeft: true, key: .window(4), departing: [1], left: { $0 == 4 }) == .afterKeyReport)
    // Kosmos's focus hid while another window stayed key, or macOS's report came first, or
    // a request found the focus gone: no report is coming, so the departure focuses.
    #expect(DepartureFocus.decide(focusLeft: true, key: .window(4), departing: [1], left: none) == .now)
    #expect(DepartureFocus.decide(focusLeft: true, key: .emptyWorkspace, departing: [1], left: none) == .now)
    #expect(DepartureFocus.decide(focusLeft: false, key: .window(1), departing: [1], left: none) == .none)
}

// The key window 1 closed and its app kept it. Whether the departure waits for macOS's
// report of the next key window depends on whether its app has another window to key.

private func afterClose(_ remaining: [DepartureFocus.OtherWindow], focusLeft: Bool = true) -> DepartureFocus {
    DepartureFocus.decide(focusLeft: focusLeft, key: .window(1), departing: [1], left: { $0 == 1 }, remaining: remaining)
}

@Test func aClosedKeyWindowWithNoOtherWindowOfItsAppFocusesAtOnce() {
    // Activity Monitor's only window closed while key: the app stayed front with no window,
    // no report came, and Helium became key only when the departure bound ended (live log,
    // September 25, 2026).
    #expect(afterClose([]) == .now)
    // A window ordered out, as one closed and kept before or a deselected tab, and one
    // minimizing are none macOS keys.
    #expect(afterClose([.init(orderedIn: false, minimized: false), .init(orderedIn: true, minimized: true)]) == .now)
    #expect(afterClose([], focusLeft: false) == .none)
}

@Test func aClosedKeyWindowWithAnotherWindowOfItsAppWaitsForTheKeyReport() {
    // macOS keys the app's other window as the window closes, and that report focuses.
    #expect(afterClose([.init(orderedIn: true, minimized: false)]) == .afterKeyReport)
}

@Test func aClosedKeyWindowWithAnotherWindowConcealedWaitsForTheKeyReport() {
    // The app's other window is concealed on a hidden workspace. A conceal leaves it
    // ordered in (kosmos-probe reveal), and macOS keyed concealed windows in 10 of 10
    // trials (docs/focus.md), so macOS may key it, and its report decides.
    let concealed = DepartureFocus.OtherWindow(orderedIn: true, minimized: false)
    #expect(afterClose([concealed]) == .afterKeyReport)
}
