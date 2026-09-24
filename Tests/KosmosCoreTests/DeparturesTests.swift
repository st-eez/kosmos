import Testing
@testable import KosmosCore

// The pieces that fixed the live Command-H re-key (tla/README.md, change 11).

private let t0 = ContinuousClock.now

@Test func aHideCountsBeforeWindowServerOrdersTheWindowOut() {
    var log = DepartureLog()
    log.left(7, at: t0)   // NSWorkspace reported the app hidden
    // WindowServer still reads the window ordered in; only a change of order counts.
    log.ordered(7, in: true, was: true, at: t0 + .milliseconds(5))
    #expect(log.left(7, within: .seconds(1), at: t0 + .milliseconds(10)) == true)
    log.ordered(7, in: false, was: true, at: t0 + .milliseconds(17))
    #expect(log.left(7, within: .seconds(1), at: t0 + .milliseconds(20)) == true)
}

@Test func aWindowIsBackOnlyWhenOrderedInAgainOrRestored() {
    var log = DepartureLog()
    log.left(7, at: t0)
    log.ordered(7, in: true, was: false, at: t0 + .milliseconds(300))
    #expect(log.left(7, within: .seconds(1), at: t0 + .milliseconds(400)) == nil)
    log.left(8, at: t0)   // minimized
    log.returned(8)       // restored
    #expect(log.left(8, within: .seconds(1), at: t0) == nil)
}

@Test func aDepartureCountsForTheBoundOnly() {
    var log = DepartureLog()
    log.left(7, at: t0)
    #expect(log.left(7, within: .seconds(1), at: t0 + .milliseconds(1100)) == false)
    #expect(log.left(9, within: .seconds(1), at: t0) == nil)
}

@Test func aHeldReportIsDecidedOnceByItsGraceOrByTheDeparture() {
    var held = HeldReport<String>()
    let first = held.hold("Ghostty", previous: 1)
    #expect(held.departed([2]) == nil)
    #expect(held.departed([1]) == "Ghostty")
    #expect(held.expire(first) == nil)   // decided already

    let second = held.hold("Helium", previous: 1)
    #expect(held.expire(second) == "Helium")
    #expect(held.report == nil)
}

@Test func aReplacedOrEndedHoldIsNotDecidedByAnOldGrace() {
    var held = HeldReport<String>()
    let first = held.hold("Ghostty", previous: 1)
    let second = held.hold("Helium", previous: 3)   // a newer report of a window to hold
    #expect(held.expire(first) == nil)
    #expect(held.report == "Helium")
    held.end()                                        // a newer activation
    #expect(held.expire(second) == nil)
    #expect(held.departed([3]) == nil)
}

@Test func aDepartureOfTheFocusWaitsOnlyForAKeyReportThatIsComing() {
    let none: (WindowID) -> Bool = { _ in false }
    // The key window minimized: macOS keys another window and reports it.
    #expect(DepartureFocus.decide(focusLeft: true, refocus: false, key: .window(1), departing: [1], left: none) == .afterKeyReport)
    // The key window left in an event not handled yet.
    #expect(DepartureFocus.decide(focusLeft: true, refocus: false, key: .window(4), departing: [1], left: { $0 == 4 }) == .afterKeyReport)
    // Kosmos's focus hid while another window stayed key, or macOS's report came first:
    // no report is coming, so the departure focuses.
    #expect(DepartureFocus.decide(focusLeft: true, refocus: false, key: .window(4), departing: [1], left: none) == .now)
    #expect(DepartureFocus.decide(focusLeft: true, refocus: false, key: KeyWindow.none, departing: [1], left: none) == .now)
    // A focus request found the window gone before the departure.
    #expect(DepartureFocus.decide(focusLeft: true, refocus: true, key: .window(1), departing: [1], left: none) == .now)
    #expect(DepartureFocus.decide(focusLeft: false, refocus: true, key: .window(1), departing: [1], left: none) == .none)
}
