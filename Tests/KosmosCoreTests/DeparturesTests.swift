import Testing
@testable import KosmosCore

// The pieces that fixed the live Command-H re-key (tla/README.md, change 11).

private let t0 = ContinuousClock.now

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

@Test func aHeldReportIsDecidedOnceByItsGrace() {
    var held = HeldReport<String>()
    let first = held.hold("Ghostty", of: .window(3))
    #expect(held.holds(.window(3), repeated: true))    // the same activation again
    #expect(!held.holds(.window(3), repeated: false))  // a new key change of the window
    #expect(held.expire(first) == "Ghostty")
    #expect(held.expire(first) == nil)
}

@Test func aReplacedOrEndedHoldIsNotDecidedByAnOldGrace() {
    var held = HeldReport<String>()
    let first = held.hold("Ghostty", of: .window(3))
    let second = held.hold("Helium", of: .window(4))   // a newer report of a window to hold
    #expect(held.expire(first) == nil)
    #expect(held.report == "Helium")
    #expect(held.end() == "Helium")                    // a newer activation
    #expect(held.expire(second) == nil)
    #expect(!held.holds(.window(4), repeated: true))
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
    #expect(DepartureFocus.decide(focusLeft: true, key: KeyWindow.none, departing: [1], left: none) == .now)
    #expect(DepartureFocus.decide(focusLeft: false, key: .window(1), departing: [1], left: none) == .none)
}

// Native tabs: a switch orders one window of the app in and another out, in either order.

@Test func aTabSwitchPairsTwoWindowsOfOneAppInEitherOrder() {
    var tabs = TabSwitches()
    // Measured order: the incoming tab joins the Space before the outgoing leaves it.
    #expect(tabs.ordered(2, in: true, app: 100, at: t0) == nil)
    #expect(tabs.ordered(1, in: false, app: 100, at: t0 + .milliseconds(3)).map { [$0.old, $0.new] } == [1, 2])
    // The other order, as when the selected tab closes first.
    #expect(tabs.ordered(2, in: false, app: 100, at: t0 + .seconds(1)) == nil)
    #expect(tabs.ordered(3, in: true, app: 100, at: t0 + .seconds(1) + .milliseconds(40)).map { [$0.old, $0.new] } == [2, 3])
}

@Test func windowsThatComeAndGoApartAreNotATabSwitch() {
    var tabs = TabSwitches()
    #expect(tabs.ordered(1, in: false, app: 100, at: t0) == nil)
    #expect(tabs.ordered(2, in: true, app: 100, at: t0 + .milliseconds(300)) == nil)    // too late
    #expect(tabs.ordered(3, in: false, app: 200, at: t0 + .milliseconds(310)) == nil)   // another app
    #expect(tabs.ordered(3, in: true, app: 200, at: t0 + .milliseconds(320)) == nil)    // the same window back
    #expect(tabs.ordered(4, in: true, app: 100, at: t0 + .milliseconds(330)) == nil)    // two in: no switch
    // The latest change pairs, and once paired the next change starts afresh.
    #expect(tabs.ordered(5, in: false, app: 100, at: t0 + .milliseconds(340)).map { [$0.old, $0.new] } == [5, 4])
    #expect(tabs.ordered(6, in: true, app: 100, at: t0 + .milliseconds(350)) == nil)
}
