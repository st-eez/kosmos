import CoreGraphics
import Testing
@testable import KosmosCore

/// The frame the tabs of a group share.
private let tile = CGRect(x: 869, y: 37, width: 849, height: 1070)

@Test func aTabSwitchPairsTwoWindowsOfOneAppInEitherOrder() {
    var tabs = TabSwitches()
    // The incoming tab joins the Space before the outgoing one leaves it (kosmos-probe tabs).
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
    #expect(order.ordered(3, app: 100, in: false, was: nil, frame: tile, at: t0 + .milliseconds(20), locked: true) == false)
    #expect(order.ordered(3, app: 100, in: true, was: nil, frame: tile, at: t0 + .milliseconds(420), locked: true) == false)
    #expect(order.ordered(4, app: 100, in: false, was: true, frame: tile, at: t0 + .milliseconds(1000), locked: true) == false)
    #expect(order.ordered(4, app: 100, in: true, was: false, frame: tile, at: t0 + .milliseconds(1100), locked: true) == false)
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
    // The sweep after the unlock.
    #expect(order.removed(1, app: 100, orderedIn: true, frame: tile, at: t0, locked: false) == false)
    #expect(order.ordered(2, app: 100, in: true, was: true, frame: tile, at: t0, locked: false) == false)
    #expect(order.ordered(3, app: 100, in: true, was: nil, frame: tile, at: t0, locked: false) == false)
    order.swept()
    // Later changes are reported again.
    #expect(order.ordered(2, app: 100, in: false, was: true, frame: tile, at: t0, locked: false) == true)
}

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
    // With another window of its app ordered out, a tab switch's order-in may still be on its
    // way to the main actor, so the look waits the pairing window.
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

@Test func aNativeFullscreenTransitionIsBackBeforeItIsJudged() {
    // The times kosmos-probe fullscreen measured (docs/tree.md).
    let enter = t0, out = enter + .milliseconds(84.2), back = enter + .milliseconds(612.4)
    #expect(judged(out, spacesChanged: enter + .milliseconds(47.1)) > back)
    let leave = t0 + .seconds(4), outAgain = leave + .milliseconds(224.8)
    #expect(judged(outAgain, spacesChanged: leave + .milliseconds(31.6)) > leave + .milliseconds(750.8))
    // A Space event that comes only after the order-out, before the look, holds it too.
    #expect(judged(out, spacesChanged: out + .milliseconds(100)) > back)
}

@Test func aTabANewTabClaimsWaitsForThatTabsAdmission() {
    // The new tab 7 is not admitted yet when tab 2 is looked at, as in an app slow to answer
    // Accessibility.
    var tabs = TabGroups()
    #expect(tabs.switched(from: 2, to: 7, admitted: false, placed: placed, sharesFrame: { _ in true }) == .pending)
    #expect(tabs.isClaimed(2) && !tabs.isClaimed(7))
    #expect(judged(t0, claimed: tabs.isClaimed(2)) == t0 + .seconds(1))
    // Admitted, 7 takes the place, and nothing claims 2.
    #expect(tabs.admitting(7) == .takes(2))
    #expect(judged(t0, claimed: tabs.isClaimed(2)) == t0)
}

@Test func aClosedTabsPlaceWaitsForTheTabThatClaimsIt() {
    // The selected tab 2 closes after its next tab 7 came in, before Kosmos admitted 7. The
    // destroy is judged at once, with no Space event, as a look is.
    var tabs = TabGroups()
    #expect(tabs.switched(from: 2, to: 7, admitted: false, placed: placed, sharesFrame: { _ in true }) == .pending)
    #expect(ClosedAndKept.hold(orderedOut: t0, claimed: tabs.isClaimed(2), sibling: false, spacesChanged: nil, at: t0)
            == .seconds(1))
    #expect(ClosedAndKept.hold(orderedOut: t0, claimed: false, sibling: true, spacesChanged: nil, at: t0) == TabSwitches.window)
    #expect(ClosedAndKept.hold(orderedOut: t0, claimed: false, sibling: false, spacesChanged: nil, at: t0) == nil)
}
