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

// Order changes while the session is locked are held with their times and reported at the
// unlock (reviews of 8e0db8e and e5e730e).

private func change(_ window: WindowID, _ orderedIn: Bool, _ ms: Int) -> HeldOrder.Change {
    HeldOrder.Change(window: window, app: 100, orderedIn: orderedIn, at: t0 + .milliseconds(ms))
}

@Test func anOrderChangeIsReportedAtOnceWhileUnlocked() {
    var order = HeldOrder()
    #expect(order.ordered(1, app: 100, in: true, was: nil, at: t0, locked: false) == true)
    #expect(order.ordered(1, app: 100, in: true, was: true, at: t0, locked: false) == false)
    #expect(order.ordered(1, app: 100, in: false, was: true, at: t0, locked: false) == true)
    #expect(order.ordered(2, app: 100, in: false, was: nil, at: t0, locked: false) == false)
    #expect(order.removed(3, app: 100, orderedIn: true, at: t0, locked: false) == true)
    #expect(order.removed(4, app: 100, orderedIn: false, at: t0, locked: false) == false)
    #expect(order.unlocked().isEmpty)
}

@Test func changesWhileLockedReplayInTheOrderTheyHappenedWithTheirTimes() {
    var order = HeldOrder()
    // The selected tab 1 closes, and tab 2 of its group is selected.
    #expect(order.removed(1, app: 100, orderedIn: true, at: t0 + .milliseconds(10), locked: true) == false)
    #expect(order.ordered(2, app: 100, in: true, was: false, at: t0 + .milliseconds(11), locked: true) == false)
    // Window 3 is created ordered out, and ordered in 400 ms later.
    #expect(order.ordered(3, app: 100, in: false, was: nil, at: t0 + .milliseconds(20), locked: true) == false)
    #expect(order.ordered(3, app: 100, in: true, was: nil, at: t0 + .milliseconds(420), locked: true) == false)
    // Window 4 is ordered out and back in.
    #expect(order.ordered(4, app: 100, in: false, was: true, at: t0 + .milliseconds(1000), locked: true) == false)
    #expect(order.ordered(4, app: 100, in: true, was: false, at: t0 + .milliseconds(1100), locked: true) == false)
    // Window 5 comes and goes before the unlock; window 6 is ordered out, then destroyed.
    #expect(order.ordered(5, app: 100, in: true, was: nil, at: t0 + .milliseconds(2000), locked: true) == false)
    #expect(order.removed(5, app: 100, orderedIn: false, at: t0 + .milliseconds(2500), locked: true) == false)
    #expect(order.ordered(6, app: 100, in: false, was: true, at: t0 + .milliseconds(3000), locked: true) == false)
    #expect(order.removed(6, app: 100, orderedIn: false, at: t0 + .milliseconds(3100), locked: true) == false)
    let held = order.unlocked()
    #expect(held == [change(1, false, 10), change(2, true, 11), change(3, true, 420),
                     change(4, false, 1000), change(4, true, 1100),
                     change(5, true, 2000), change(5, false, 2500), change(6, false, 3000)])
    #expect(order.unlocked().isEmpty)
    // Paired as they would have been unlocked: only the tab switch of 1 and 2.
    var tabs = TabSwitches()
    let switches = held.compactMap { tabs.ordered($0.window, in: $0.orderedIn, app: $0.app, at: $0.at) }
    #expect(switches.map { [$0.old, $0.new] } == [[1, 2]])
}

@Test func theSweepAfterTheUnlockReportsNothingTheReplayReported() {
    var order = HeldOrder()
    _ = order.removed(1, app: 100, orderedIn: true, at: t0, locked: true)
    _ = order.ordered(2, app: 100, in: true, was: false, at: t0, locked: true)
    _ = order.ordered(3, app: 100, in: true, was: nil, at: t0, locked: true)
    _ = order.unlocked()
    // It removes 1, reads 2 unchanged since the lock, and admits 3.
    #expect(order.removed(1, app: 100, orderedIn: true, at: t0, locked: false) == false)
    #expect(order.ordered(2, app: 100, in: true, was: true, at: t0, locked: false) == false)
    #expect(order.ordered(3, app: 100, in: true, was: nil, at: t0, locked: false) == false)
    order.swept()
    // Later changes are reported again.
    #expect(order.ordered(2, app: 100, in: false, was: true, at: t0, locked: false) == true)
}

// Only an admitted window takes a place (review of 5107ed0, (a) and (d)).

private let places: Set<WindowID> = [2]
private func placed(_ window: WindowID) -> Bool { places.contains(window) }

@Test func aTabSelectedBeforeItsAdmissionTakesThePlaceOnceAdmitted() {
    var tabs = TabGroups()
    // Command-T: the new tab 7 is selected before Kosmos reads its Accessibility role.
    #expect(tabs.switched(from: 2, to: 7, admitted: false, placed: placed) == .pending)
    #expect(tabs.admitting(7) == .takes(2))
    #expect(tabs.switched(from: 2, to: 7, admitted: true, placed: placed) == .replace(2))
    tabs.replaced(2, with: 7)
    #expect(tabs.hidden == [2])
    #expect(tabs.admitting(9) == .own)   // a window that took no tab's place
}

@Test func aTabDeselectedBeforeItsAdmissionStaysAHiddenMember() {
    var tabs = TabGroups()
    #expect(tabs.switched(from: 2, to: 7, admitted: false, placed: placed) == .pending)
    // Back to tab 2 before 7's admission: 7 never took the place, and 2 keeps it.
    #expect(tabs.switched(from: 7, to: 2, admitted: true, placed: placed) == .none)
    #expect(tabs.admitting(7) == .hidden)
    // A switch from a tab that holds no place, as one destroyed first, places nothing.
    #expect(tabs.switched(from: 3, to: 4, admitted: true, placed: placed) == .none)
}

@Test func aClaimPassesAlongTabsSelectedBeforeTheirAdmission() {
    var tabs = TabGroups()
    // Command-T twice, or Finder opening several tabs, before either new tab is admitted.
    #expect(tabs.switched(from: 2, to: 7, admitted: false, placed: placed) == .pending)
    #expect(tabs.switched(from: 7, to: 8, admitted: false, placed: placed) == .pending)
    #expect(tabs.admitting(7) == .hidden)
    #expect(tabs.admitting(8) == .takes(2))
    // Admitted already, the next tab takes the place at once.
    var admitted = TabGroups()
    _ = admitted.switched(from: 2, to: 7, admitted: false, placed: placed)
    #expect(admitted.switched(from: 7, to: 5, admitted: true, placed: placed) == .replace(2))
}

@Test func aHiddenMemberDraggedOutOrGoneLeavesTheGroup() {
    var tabs = TabGroups()
    tabs.replaced(2, with: 7)
    #expect(tabs.detached(2) && !tabs.detached(2))
    tabs.replaced(7, with: 8)
    _ = tabs.switched(from: 8, to: 9, admitted: false, placed: { _ in true })   // 9 pending on 8
    tabs.forget(8)
    #expect(tabs.admitting(9) == .own)
    tabs.forget(7)
    #expect(tabs.hidden.isEmpty)
}
