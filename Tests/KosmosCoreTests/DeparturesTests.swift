import CoreGraphics
import Testing
@testable import KosmosCore

// The pieces that fixed the live Command-H re-key (tla/README.md, change 11).

private let t0 = ContinuousClock.now
/// The frame the tabs of a group share.
private let tile = CGRect(x: 869, y: 37, width: 849, height: 1070)

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

@Test func aRepeatOfTheLastKeyWindowHasTheWindowBeforeIt() {   // change 24
    // The key window 2 hides, and macOS keys 1, concealed on another workspace. Its
    // notification finds 2 gone, and the activation read of the same change, which repeats
    // 1, has to find 2 gone too, or Kosmos follows macOS's re-key.
    var keys = KeyHistory()
    _ = keys.heard(.window(2))
    #expect(keys.heard(.window(1)) == .window(2))
    #expect(keys.heard(.window(1)) == .window(2))
    #expect(keys.heard(.window(3)) == .window(1))
    #expect(keys.key == .window(3))
    // No key window after 3 left, then another app's report of none: that one has none.
    #expect(keys.heard(.none) == .window(3))
    #expect(keys.heard(.none) == KeyWindow.none)
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

// Native tabs: a switch orders one window of the app in and another out, in either order.

@Test func aTabSwitchPairsTwoWindowsOfOneAppInEitherOrder() {
    var tabs = TabSwitches()
    // Measured order: the incoming tab joins the Space before the outgoing leaves it.
    #expect(tabs.ordered(2, in: true, frame: tile, app: 100, at: t0) == nil)
    #expect(tabs.ordered(1, in: false, frame: tile, app: 100, at: t0 + .milliseconds(3)).map { [$0.old, $0.new] } == [1, 2])
    // The other order, as when the selected tab closes first.
    #expect(tabs.ordered(2, in: false, frame: tile, app: 100, at: t0 + .seconds(1)) == nil)
    #expect(tabs.ordered(3, in: true, frame: tile, app: 100, at: t0 + .seconds(1) + .milliseconds(40)).map { [$0.old, $0.new] } == [2, 3])
}

@Test func windowsThatComeAndGoApartAreNotATabSwitch() {
    var tabs = TabSwitches()
    #expect(tabs.ordered(1, in: false, frame: tile, app: 100, at: t0) == nil)
    #expect(tabs.ordered(2, in: true, frame: tile, app: 100, at: t0 + .milliseconds(300)) == nil)    // too late
    #expect(tabs.ordered(3, in: false, frame: tile, app: 200, at: t0 + .milliseconds(310)) == nil)   // another app
    #expect(tabs.ordered(3, in: true, frame: tile, app: 200, at: t0 + .milliseconds(320)) == nil)    // the same window back
    #expect(tabs.ordered(4, in: true, frame: tile, app: 100, at: t0 + .milliseconds(330)) == nil)    // two in: no switch
    // The latest change pairs, and once paired the next change starts afresh.
    #expect(tabs.ordered(5, in: false, frame: tile, app: 100, at: t0 + .milliseconds(340)).map { [$0.old, $0.new] } == [5, 4])
    #expect(tabs.ordered(6, in: true, frame: tile, app: 100, at: t0 + .milliseconds(350)) == nil)
}

// Only windows with one frame pair: tabs share theirs (kosmos-probe tabs), and a native
// fullscreen window's toolbar window and a window leaving fullscreen do not (live log,
// September 24, 2026).

private let display = CGRect(x: 0, y: 0, width: 1728, height: 1117)
private let toolbar = CGRect(x: 0, y: 0, width: 1728, height: 52)

@Test func aFullscreenExitAndItsToolbarWindowsAreNoTabSwitch() {
    var tabs = TabSwitches()
    // Terminal restores 91833 into fullscreen, and its toolbar window 91834 comes in.
    #expect(tabs.ordered(91833, in: false, frame: display, app: 100, at: t0) == nil)
    #expect(tabs.ordered(91834, in: true, frame: toolbar, app: 100, at: t0 + .milliseconds(100)) == nil)
    // 91857 leaves fullscreen: its toolbar window 91858 goes, it comes back as a tile, and
    // 91833's toolbar window 91834 goes too, within 250 ms of it.
    let exit = t0 + .seconds(20)
    #expect(tabs.ordered(91858, in: false, frame: toolbar, app: 100, at: exit) == nil)
    #expect(tabs.ordered(91857, in: true, frame: tile, app: 100, at: exit + .milliseconds(400)) == nil)
    #expect(tabs.ordered(91834, in: false, frame: toolbar, app: 100, at: exit + .milliseconds(554)) == nil)
}

@Test func aTabSwitchPairsAcrossAChangeOfAnotherFrame() {
    var tabs = TabSwitches()
    // A switch inside a fullscreen group, with its toolbar window reordered between the
    // two halves.
    #expect(tabs.ordered(5, in: true, frame: display, app: 100, at: t0) == nil)
    #expect(tabs.ordered(9, in: false, frame: toolbar, app: 100, at: t0 + .milliseconds(1)) == nil)
    #expect(tabs.ordered(6, in: false, frame: display, app: 100, at: t0 + .milliseconds(2)).map { [$0.old, $0.new] } == [6, 5])
    // A window closing and another opening at once, cascaded from it, is no switch.
    let later = t0 + .seconds(1)
    #expect(tabs.ordered(7, in: false, frame: tile, app: 100, at: later) == nil)
    #expect(tabs.ordered(8, in: true, frame: tile.offsetBy(dx: 22, dy: 22), app: 100, at: later + .milliseconds(30)) == nil)
}

// Order changes while the session is locked are held with their times and reported at the
// unlock (reviews of 8e0db8e and e5e730e).

private func change(_ window: WindowID, _ orderedIn: Bool, _ ms: Int) -> HeldOrder.Change {
    HeldOrder.Change(window: window, app: 100, orderedIn: orderedIn, frame: tile, at: t0 + .milliseconds(ms))
}

@Test func anOrderChangeIsReportedAtOnceWhileUnlocked() {
    var order = HeldOrder()
    #expect(order.ordered(1, app: 100, in: true, was: nil, frame: tile, at: t0, locked: false) == true)
    #expect(order.ordered(1, app: 100, in: true, was: true, frame: tile, at: t0, locked: false) == false)
    #expect(order.ordered(1, app: 100, in: false, was: true, frame: tile, at: t0, locked: false) == true)
    #expect(order.ordered(2, app: 100, in: false, was: nil, frame: tile, at: t0, locked: false) == false)
    #expect(order.removed(3, app: 100, orderedIn: true, frame: tile, at: t0, locked: false) == true)
    #expect(order.removed(4, app: 100, orderedIn: false, frame: tile, at: t0, locked: false) == false)
    #expect(order.unlocked().isEmpty)
}

@Test func changesWhileLockedReplayInTheOrderTheyHappenedWithTheirTimes() {
    var order = HeldOrder()
    // The selected tab 1 closes, and tab 2 of its group is selected.
    #expect(order.removed(1, app: 100, orderedIn: true, frame: tile, at: t0 + .milliseconds(10), locked: true) == false)
    #expect(order.ordered(2, app: 100, in: true, was: false, frame: tile, at: t0 + .milliseconds(11), locked: true) == false)
    // Window 3 is created ordered out, and ordered in 400 ms later.
    #expect(order.ordered(3, app: 100, in: false, was: nil, frame: tile, at: t0 + .milliseconds(20), locked: true) == false)
    #expect(order.ordered(3, app: 100, in: true, was: nil, frame: tile, at: t0 + .milliseconds(420), locked: true) == false)
    // Window 4 is ordered out and back in.
    #expect(order.ordered(4, app: 100, in: false, was: true, frame: tile, at: t0 + .milliseconds(1000), locked: true) == false)
    #expect(order.ordered(4, app: 100, in: true, was: false, frame: tile, at: t0 + .milliseconds(1100), locked: true) == false)
    // Window 5 comes and goes before the unlock; window 6 is ordered out, then destroyed.
    #expect(order.ordered(5, app: 100, in: true, was: nil, frame: tile, at: t0 + .milliseconds(2000), locked: true) == false)
    #expect(order.removed(5, app: 100, orderedIn: false, frame: tile, at: t0 + .milliseconds(2500), locked: true) == false)
    #expect(order.ordered(6, app: 100, in: false, was: true, frame: tile, at: t0 + .milliseconds(3000), locked: true) == false)
    #expect(order.removed(6, app: 100, orderedIn: false, frame: tile, at: t0 + .milliseconds(3100), locked: true) == false)
    let held = order.unlocked()
    #expect(held == [change(1, false, 10), change(2, true, 11), change(3, true, 420),
                     change(4, false, 1000), change(4, true, 1100),
                     change(5, true, 2000), change(5, false, 2500), change(6, false, 3000)])
    #expect(order.unlocked().isEmpty)
    // Paired as they would have been unlocked: only the tab switch of 1 and 2.
    var tabs = TabSwitches()
    let switches = held.compactMap { tabs.ordered($0.window, in: $0.orderedIn, frame: $0.frame, app: $0.app, at: $0.at) }
    #expect(switches.map { [$0.old, $0.new] } == [[1, 2]])
}

@Test func theSweepAfterTheUnlockReportsNothingTheReplayReported() {
    var order = HeldOrder()
    _ = order.removed(1, app: 100, orderedIn: true, frame: tile, at: t0, locked: true)
    _ = order.ordered(2, app: 100, in: true, was: false, frame: tile, at: t0, locked: true)
    _ = order.ordered(3, app: 100, in: true, was: nil, frame: tile, at: t0, locked: true)
    _ = order.unlocked()
    // It removes 1, reads 2 unchanged since the lock, and admits 3.
    #expect(order.removed(1, app: 100, orderedIn: true, frame: tile, at: t0, locked: false) == false)
    #expect(order.ordered(2, app: 100, in: true, was: true, frame: tile, at: t0, locked: false) == false)
    #expect(order.ordered(3, app: 100, in: true, was: nil, frame: tile, at: t0, locked: false) == false)
    order.swept()
    // Later changes are reported again.
    #expect(order.ordered(2, app: 100, in: false, was: true, frame: tile, at: t0, locked: false) == true)
}

// Only an admitted window takes a place (review of 5107ed0, (a) and (d)).

private let places: Set<WindowID> = [2]
private func placed(_ window: WindowID) -> Bool { places.contains(window) }

@Test func aTabSelectedBeforeItsAdmissionTakesThePlaceOnceAdmitted() {
    var tabs = TabGroups()
    // Command-T: the new tab 7 is selected before Kosmos reads its Accessibility role.
    #expect(tabs.switched(from: 2, to: 7, admitted: false, placed: placed, sharesFrame: { _ in true }) == .pending)
    #expect(tabs.admitting(7) == .takes(2))
    #expect(tabs.switched(from: 2, to: 7, admitted: true, placed: placed, sharesFrame: { _ in true }) == .replace(2))
    tabs.replaced(2, with: 7)
    #expect(tabs.hidden == [2])
    #expect(tabs.admitting(9) == .own)   // a window that took no tab's place
}

@Test func aTabDeselectedBeforeItsAdmissionStaysAHiddenMember() {
    var tabs = TabGroups()
    #expect(tabs.switched(from: 2, to: 7, admitted: false, placed: placed, sharesFrame: { _ in true }) == .pending)
    // Back to tab 2 before 7's admission: 7 never took the place, and 2 keeps it.
    #expect(tabs.switched(from: 7, to: 2, admitted: true, placed: placed, sharesFrame: { _ in true }) == .none)
    #expect(tabs.admitting(7) == .hidden)
    // A switch from a tab that holds no place, as one destroyed first, places nothing.
    #expect(tabs.switched(from: 3, to: 4, admitted: true, placed: placed, sharesFrame: { _ in true }) == .none)
}

@Test func aClaimPassesAlongTabsSelectedBeforeTheirAdmission() {
    var tabs = TabGroups()
    // Command-T twice, or Finder opening several tabs, before either new tab is admitted.
    #expect(tabs.switched(from: 2, to: 7, admitted: false, placed: placed, sharesFrame: { _ in true }) == .pending)
    #expect(tabs.switched(from: 7, to: 8, admitted: false, placed: placed, sharesFrame: { _ in true }) == .pending)
    #expect(tabs.admitting(7) == .hidden)
    #expect(tabs.admitting(8) == .takes(2))
    // Admitted already, the next tab takes the place at once.
    var admitted = TabGroups()
    _ = admitted.switched(from: 2, to: 7, admitted: false, placed: placed, sharesFrame: { _ in true })
    #expect(admitted.switched(from: 7, to: 5, admitted: true, placed: placed, sharesFrame: { _ in true }) == .replace(2))
}

@Test func aClaimPassesOnlyToAHolderWithTheSwitchFrame() {
    // 7 was selected before its admission and claimed 2's place, a fullscreen tab's. 7 is
    // deselected for 8. 8 takes 2's place only with 2's frame.
    var tabs = TabGroups()
    #expect(tabs.switched(from: 2, to: 7, admitted: false, placed: placed, sharesFrame: { _ in true }) == .pending)
    var other = tabs
    #expect(other.switched(from: 7, to: 8, admitted: true, placed: placed, sharesFrame: { $0 != 2 }) == .none)
    #expect(other.hidden.contains(7))
    #expect(tabs.switched(from: 7, to: 8, admitted: true, placed: placed, sharesFrame: { $0 == 2 }) == .replace(2))
}

@Test func aHiddenMemberDraggedOutOrGoneLeavesTheGroup() {
    var tabs = TabGroups()
    tabs.replaced(2, with: 7)
    #expect(tabs.detached(2) && !tabs.detached(2))
    tabs.replaced(7, with: 8)
    _ = tabs.switched(from: 8, to: 9, admitted: false, placed: { _ in true }, sharesFrame: { _ in true })   // 9 pending on 8
    tabs.forget(8)
    #expect(tabs.admitting(9) == .own)
    tabs.forget(7)
    #expect(tabs.hidden.isEmpty)
}

// A window its app closed and kept is looked at as the read that saw its order-out is
// applied, and parks then unless a native fullscreen transition may be under way, a new
// tab claims its place or its app has another window ordered out. Activity Monitor's
// Command-W waited a second before its neighbor reflowed, and then 257 and 267 ms at a
// 250 ms pairing window (live log, September 25, 2026).

/// When a window seen ordered out at `out`, and looked at then, parks.
private func judged(_ out: ContinuousClock.Instant, claimed: Bool = false, sibling: Bool = false,
                    spacesChanged: ContinuousClock.Instant? = nil) -> ContinuousClock.Instant {
    out + (ClosedAndKept.hold(orderedOut: out, claimed: claimed, sibling: sibling, spacesChanged: spacesChanged, at: out) ?? .zero)
}

@Test func aWindowClosedAndKeptParksAtItsOrderOut() {
    #expect(judged(t0) == t0)
    // A Space event more than a second before is no transition of this window's.
    #expect(judged(t0, spacesChanged: t0 - .seconds(2)) == t0)
}

@Test func aWindowWhoseAppHasAnotherWindowOrderedOutWaitsForATabSwitch() {
    // Activity Monitor's only window, closed, parks at once. Closing the selected Ghostty
    // tab orders it out while the next tab is still ordered out, and that tab's order-in
    // may still be on its way to the main actor, so the look waits the pairing window.
    #expect(judged(t0) == t0)
    #expect(judged(t0, sibling: true) == t0 + TabSwitches.window)
    // A native fullscreen transition waits longer.
    #expect(judged(t0, sibling: true, spacesChanged: t0 - .milliseconds(40)) == t0 + .seconds(1))
}

@Test func aTabSwitchWhoseHalvesCameInTwoReadsPairsBeforeTheLook() {
    // The outgoing tab's order-out and the incoming tab's order-in, 0.2 ms apart at
    // WindowServer, fall in two reads, the second asked for before the first is applied.
    var looks = ClosedAndKept.Looks()
    looks.readAsked()
    looks.readAsked()
    looks.orderedOut(1, at: t0)
    #expect(looks.readApplied(eventsWaiting: false).isEmpty)
    #expect(looks.readApplied(eventsWaiting: false).map(\.window) == [1])
    // An event that waits for its read holds the look for that read too.
    looks.readAsked()
    looks.orderedOut(3, at: t0 + .seconds(1))
    #expect(looks.readApplied(eventsWaiting: true).isEmpty)
    looks.readAsked()
    #expect(looks.readApplied(eventsWaiting: false).map(\.window) == [3])
}

// kosmos-probe fullscreen, September 23, 2026, from the child's toggleFullScreen. Entering:
// Spaces created at 38 to 47 ms, ordered out at 84 ms, in the fullscreen Space at 574 ms,
// ordered in at 612 ms. Leaving: Spaces created at 25 and 32 ms, ordered out at 225 ms, on
// the desktop Space at 543 ms, where it stops counting as in fullscreen, ordered in at 751 ms.

@Test func aNativeFullscreenTransitionIsBackBeforeItIsJudged() {
    let enter = t0, out = enter + .milliseconds(84.2), back = enter + .milliseconds(612.4)
    #expect(judged(out, spacesChanged: enter + .milliseconds(47.1)) > back)
    let leave = t0 + .seconds(4), outAgain = leave + .milliseconds(224.8)
    #expect(judged(outAgain, spacesChanged: leave + .milliseconds(31.6)) > leave + .milliseconds(750.8))
    // A Space event that comes only after the order-out, before the look, holds it too.
    #expect(judged(out, spacesChanged: out + .milliseconds(100)) > back)
}

@Test func aTabANewTabClaimsWaitsForThatTabsAdmission() {
    // Command-T in an app slow to answer Accessibility: the new tab 7, selected, is not
    // admitted yet when tab 2 is looked at. Never admitted, 2 parks a second after its
    // order-out.
    var tabs = TabGroups()
    #expect(tabs.switched(from: 2, to: 7, admitted: false, placed: placed, sharesFrame: { _ in true }) == .pending)
    #expect(tabs.isClaimed(2) && !tabs.isClaimed(7))
    #expect(judged(t0, claimed: tabs.isClaimed(2)) == t0 + .seconds(1))
    // Admitted, 7 takes the place, and nothing claims 2.
    #expect(tabs.admitting(7) == .takes(2))
    #expect(judged(t0, claimed: tabs.isClaimed(2)) == t0)
}
