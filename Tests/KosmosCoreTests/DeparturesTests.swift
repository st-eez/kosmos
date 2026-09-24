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

// Order changes while the session is locked wait for the unlock sweep (review of 8e0db8e).

@Test func anOrderChangeIsReportedOnceAndANewWindowOnlyOrderedIn() {
    var order = HeldOrder()
    #expect(order.ordered(1, in: true, was: nil, locked: false) == true)
    #expect(order.ordered(1, in: true, was: true, locked: false) == false)
    #expect(order.ordered(1, in: false, was: true, locked: false) == true)
    #expect(order.ordered(2, in: false, was: nil, locked: false) == false)
}

@Test func orderChangesWhileLockedAreReportedByTheFirstReadAfter() {
    var order = HeldOrder()
    // Tab 1 deselected and tab 2 selected while locked: nothing is reported then.
    #expect(order.ordered(1, in: false, was: true, locked: true) == false)
    #expect(order.ordered(2, in: true, was: false, locked: true) == false)
    // Tab 3 out and back in while locked: it ends as the controller heard it.
    #expect(order.ordered(3, in: false, was: true, locked: true) == false)
    #expect(order.ordered(3, in: true, was: false, locked: true) == false)
    // The unlock sweep reads each row again, unchanged since the lock.
    #expect(order.ordered(1, in: false, was: false, locked: false) == true)
    #expect(order.ordered(2, in: true, was: true, locked: false) == true)
    #expect(order.ordered(3, in: true, was: true, locked: false) == false)
    #expect(order.ordered(1, in: false, was: false, locked: false) == false)
}

@Test func aRemovedWindowLastHeardOrderedInIsReportedOut() {
    var order = HeldOrder()
    #expect(order.removed(1, orderedIn: true) == true)
    #expect(order.removed(2, orderedIn: false) == false)
    // Ordered out while locked, then gone: the controller still heard it ordered in.
    #expect(order.ordered(3, in: false, was: true, locked: true) == false)
    #expect(order.removed(3, orderedIn: false) == true)
    // Ordered in while locked, then gone: it was never heard ordered in.
    #expect(order.ordered(4, in: true, was: false, locked: true) == false)
    #expect(order.removed(4, orderedIn: true) == false)
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
