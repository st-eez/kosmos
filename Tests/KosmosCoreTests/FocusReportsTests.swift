import Testing
@testable import KosmosCore

// Each test replays a counterexample TLC found in tla/Kosmos.tla (tla/README.md, "Design
// changes found by the model").

@Test func ownRequestComesBackAsAnEcho() {
    var reports = FocusReports()
    reports.focusRequested(.window(1), app: nil, at: t0 + .milliseconds(10))
    #expect(reports.classify(.window(1), receivedAt: t0 + .milliseconds(11), onShownWorkspace: true, concealed: false, keyLeft: .stayed) == .echo)
    #expect(reports.classify(.window(1), receivedAt: t0 + .milliseconds(12), onShownWorkspace: true, concealed: false, keyLeft: .stayed) == .adopt(1))
}

@Test func commandTabReportedAfterANewerCommandIsStale() {   // change 1
    var reports = FocusReports()
    reports.commandExecuted(receivedAt: t0 + .milliseconds(20))
    #expect(reports.classify(.window(3), receivedAt: t0 + .milliseconds(15), onShownWorkspace: false, concealed: true, keyLeft: .stayed) == .reassert)
}

@Test func anotherWindowOfTheIntendedAppIsNotAnEcho() {      // change 4
    var reports = FocusReports()
    reports.focusRequested(.window(1), app: nil, at: t0 + .milliseconds(10))
    #expect(reports.classify(.window(3), receivedAt: t0 + .milliseconds(11), onShownWorkspace: false, concealed: true, keyLeft: .stayed) == .follow(3))
}

@Test func reportReceivedBeforeTheRequestIsNotItsEcho() {    // change 5
    var reports = FocusReports()
    reports.focusRequested(.window(3), app: nil, at: t0 + .milliseconds(10))
    #expect(reports.classify(.window(3), receivedAt: t0 + .milliseconds(9), onShownWorkspace: true, concealed: false, keyLeft: .stayed) == .adopt(3))
    #expect(reports.classify(.window(3), receivedAt: t0 + .milliseconds(11), onShownWorkspace: true, concealed: false, keyLeft: .stayed) == .echo)
}

@Test func foreignReportKeepsExpectations() {                // change 6
    var reports = FocusReports()
    reports.focusRequested(.window(1), app: nil, at: t0 + .milliseconds(10))
    #expect(reports.classify(.window(2), receivedAt: t0 + .milliseconds(11), onShownWorkspace: true, concealed: false, keyLeft: .stayed) == .adopt(2))
    #expect(reports.classify(.window(1), receivedAt: t0 + .milliseconds(12), onShownWorkspace: true, concealed: false, keyLeft: .stayed) == .echo)
}

@Test func visibleWindowOfAnotherWorkspaceIsNotFollowed() {  // change 7
    var reports = FocusReports()
    #expect(reports.classify(.window(5), receivedAt: t0 + .milliseconds(11), onShownWorkspace: false, concealed: false, keyLeft: .stayed) == .reassert)
}

@Test func laterEchoDropsEarlierExpectations() {
    var reports = FocusReports()
    reports.focusRequested(.window(1), app: nil, at: t0 + .milliseconds(10))
    reports.focusRequested(.window(2), app: nil, at: t0 + .milliseconds(11))
    #expect(reports.classify(.window(2), receivedAt: t0 + .milliseconds(12), onShownWorkspace: true, concealed: false, keyLeft: .stayed) == .echo)
    #expect(reports.classify(.window(1), receivedAt: t0 + .milliseconds(13), onShownWorkspace: true, concealed: false, keyLeft: .stayed) == .adopt(1))
}

@Test func emptyWorkspaceFocusIsAnEchoAndOtherwiseIgnored() {
    var reports = FocusReports()
    reports.focusRequested(.noWindow, app: nil, at: t0 + .milliseconds(10))
    #expect(reports.classify(.noWindow, receivedAt: t0 + .milliseconds(11), onShownWorkspace: false, concealed: false, keyLeft: .stayed) == .echo)
    #expect(reports.classify(.noWindow, receivedAt: t0 + .milliseconds(12), onShownWorkspace: false, concealed: false, keyLeft: .stayed) == .ignore)
}

@Test func droppedRequestDoesNotSwallowAUserReport() {
    var reports = FocusReports()
    reports.focusRequested(.window(1), app: nil, at: t0 + .milliseconds(10))
    reports.requestDropped(.window(1), at: t0 + .milliseconds(10))
    #expect(reports.classify(.window(1), receivedAt: t0 + .milliseconds(11), onShownWorkspace: true, concealed: false, keyLeft: .stayed) == .adopt(1))
}

// Change 8: the key window leaves, and macOS keys another window itself.

@Test func reKeyOntoAHiddenWindowAfterTheKeyWindowLeavesIsNotFollowed() {
    var reports = FocusReports()
    #expect(reports.classify(.window(3), receivedAt: t0 + .milliseconds(11), onShownWorkspace: false, concealed: true, keyLeft: .left) == .reassert)
}

@Test func commandTabSoonAfterAHideIsStillFollowed() {
    var reports = FocusReports()
    #expect(reports.classify(.window(2), receivedAt: t0 + .milliseconds(11), onShownWorkspace: true, concealed: false, keyLeft: .left) == .adopt(2))
    #expect(reports.classify(.window(3), receivedAt: t0 + .milliseconds(12), onShownWorkspace: false, concealed: true, keyLeft: .unknown) == .undecided)
    #expect(reports.classify(.window(3), receivedAt: t0 + .milliseconds(12), onShownWorkspace: false, concealed: true, keyLeft: .stayed) == .follow(3))
}

@Test func noKeyWindowAfterTheKeyWindowLeavesFocusesTheWorkspaceAgain() {
    var reports = FocusReports()
    #expect(reports.classify(.noWindow, receivedAt: t0 + .milliseconds(11), onShownWorkspace: false, concealed: false, keyLeft: .left) == .reassert)
}

@Test func ownRequestStillComesBackAsAnEchoAfterTheKeyWindowLeaves() {
    var reports = FocusReports()
    reports.focusRequested(.window(2), app: nil, at: t0 + .milliseconds(10))
    #expect(reports.classify(.window(2), receivedAt: t0 + .milliseconds(11), onShownWorkspace: true, concealed: false, keyLeft: .left) == .echo)
}

// Change 10: a command comes before Kosmos handles a window's return.

@Test func aReturnReceivedBeforeTheLatestCommandIsStale() {
    var reports = FocusReports()
    #expect(!reports.isStale(t0 + .milliseconds(10)))
    reports.commandExecuted(receivedAt: t0 + .milliseconds(12))
    #expect(reports.isStale(t0 + .milliseconds(11)))
    #expect(!reports.isStale(t0 + .milliseconds(12)))
    #expect(!reports.isStale(t0 + .milliseconds(13)))
}

// Change 11: WindowServer shows a hidden app's window for a moment after macOS keyed the
// next window, so the departure can be unknown when the report arrives.

@Test func aReportThatDependsOnAnUnknownDepartureIsHeld() {
    var reports = FocusReports()
    #expect(reports.classify(.window(3), receivedAt: t0 + .milliseconds(11), onShownWorkspace: false, concealed: true, keyLeft: .unknown) == .undecided)
    #expect(reports.classify(.noWindow, receivedAt: t0 + .milliseconds(11), onShownWorkspace: false, concealed: false, keyLeft: .unknown) == .ignore)
    #expect(reports.classify(.window(3), receivedAt: t0 + .milliseconds(11), onShownWorkspace: false, concealed: true, keyLeft: .left) == .reassert)
    #expect(reports.classify(.window(3), receivedAt: t0 + .milliseconds(11), onShownWorkspace: false, concealed: true, keyLeft: .stayed) == .follow(3))
}

@Test func aReportThatDoesNotDependOnTheDepartureIsNotHeld() {
    var reports = FocusReports()
    reports.focusRequested(.window(2), app: nil, at: t0 + .milliseconds(10))
    #expect(reports.classify(.window(2), receivedAt: t0 + .milliseconds(11), onShownWorkspace: true, concealed: false, keyLeft: .unknown) == .echo)
    #expect(reports.classify(.window(1), receivedAt: t0 + .milliseconds(12), onShownWorkspace: true, concealed: false, keyLeft: .unknown) == .adopt(1))
    #expect(reports.classify(.window(5), receivedAt: t0 + .milliseconds(13), onShownWorkspace: false, concealed: false, keyLeft: .unknown) == .reassert)
    reports.commandExecuted(receivedAt: t0 + .milliseconds(20))
    #expect(reports.classify(.window(3), receivedAt: t0 + .milliseconds(14), onShownWorkspace: false, concealed: true, keyLeft: .unknown) == .reassert)
}

// Change 12: fronting another window of the app that is already key leaves that app's key
// window, which the app reports again.

@Test func aRepeatOfAConcealedKeyWindowDuringOurRequestToItsAppIsAMiss() {
    var reports = FocusReports()
    reports.focusRequested(.window(86737), app: 100, at: t0 + .milliseconds(10))
    let miss = reports.miss(.window(90919), app: 100, repeated: true, receivedAt: t0 + .milliseconds(11))
    #expect(miss == .retry)
    #expect(reports.classify(.window(90919), receivedAt: t0 + .milliseconds(11), onShownWorkspace: false, concealed: true,
                             miss: miss, keyLeft: .stayed) == .reassert)
}

@Test func aMissIsRetriedOnceThenTheKeyWindowIsAccepted() {
    var reports = FocusReports()
    reports.focusRequested(.window(86737), app: 100, at: t0 + .milliseconds(10))
    #expect(reports.miss(.window(90919), app: 100, repeated: true, receivedAt: t0 + .milliseconds(11)) == .retry)
    reports.focusRequested(.window(86737), app: 100, at: t0 + .milliseconds(12))   // the retry
    let second = reports.miss(.window(90919), app: 100, repeated: true, receivedAt: t0 + .milliseconds(13))
    #expect(second == .accept)
    #expect(reports.classify(.window(90919), receivedAt: t0 + .milliseconds(13), onShownWorkspace: false, concealed: true,
                             miss: second, keyLeft: .stayed) == .ignore)
    reports.focusRequested(.window(5), app: 100, at: t0 + .milliseconds(14))
    #expect(reports.miss(.window(90919), app: 100, repeated: true, receivedAt: t0 + .milliseconds(15)) == .retry)
}

@Test func aMissOnTheShownWorkspaceIsNotTheUsersChoiceEither() {
    var reports = FocusReports()
    reports.focusRequested(.window(2), app: 100, at: t0 + .milliseconds(10))
    let miss = reports.miss(.window(1), app: 100, repeated: true, receivedAt: t0 + .milliseconds(11))
    #expect(reports.classify(.window(1), receivedAt: t0 + .milliseconds(11), onShownWorkspace: true, concealed: false,
                             miss: miss, keyLeft: .stayed) == .reassert)
    reports.focusRequested(.window(2), app: 100, at: t0 + .milliseconds(12))
    let accepted = reports.miss(.window(1), app: 100, repeated: true, receivedAt: t0 + .milliseconds(13))
    #expect(reports.classify(.window(1), receivedAt: t0 + .milliseconds(13), onShownWorkspace: true, concealed: false,
                             miss: accepted, keyLeft: .stayed) == .adopt(1))
}

@Test func aMissedRequestNoLongerTakesAReportOfItsWindowForItsEcho() {
    var reports = FocusReports()
    reports.focusRequested(.window(1), app: 100, at: t0 + .milliseconds(10))
    reports.focusRequested(.window(1), app: 100, at: t0 + .milliseconds(11))
    #expect(reports.miss(.window(3), app: 100, repeated: true, receivedAt: t0 + .milliseconds(12)) == .retry)
    #expect(reports.classify(.window(1), receivedAt: t0 + .milliseconds(13), onShownWorkspace: true, concealed: false, keyLeft: .stayed) == .echo)
    #expect(reports.classify(.window(1), receivedAt: t0 + .milliseconds(14), onShownWorkspace: false, concealed: true, keyLeft: .stayed) == .follow(1))
}

@Test func anEchoOfTheRaiseAfterAKeyRecordIsNoMiss() {
    var reports = FocusReports()
    // An app can report the key record's window again after the raise that follows it
    // (kosmos-probe keying).
    reports.focusRequested(.window(1), app: 100, at: t0 + .milliseconds(10))
    #expect(reports.classify(.window(1), receivedAt: t0 + .milliseconds(11), onShownWorkspace: true, concealed: false, keyLeft: .stayed) == .echo)
    reports.focusRequested(.window(1), app: 100, at: t0 + .milliseconds(12))   // the raise
    reports.focusRequested(.window(2), app: 100, at: t0 + .milliseconds(13))
    #expect(reports.miss(.window(1), app: 100, repeated: true, receivedAt: t0 + .milliseconds(14)) == .none)
    #expect(reports.classify(.window(1), receivedAt: t0 + .milliseconds(14), onShownWorkspace: true, concealed: false, keyLeft: .stayed) == .echo)
    #expect(reports.classify(.window(2), receivedAt: t0 + .milliseconds(15), onShownWorkspace: true, concealed: false, keyLeft: .stayed) == .echo)
}

@Test func openingAConcealedWindowOfTheRequestedAppIsTheUsersChoice() {
    var reports = FocusReports()
    reports.focusRequested(.window(1), app: 100, at: t0 + .milliseconds(10))
    let miss = reports.miss(.window(3), app: 100, repeated: false, receivedAt: t0 + .milliseconds(11))
    #expect(miss == .none)
    #expect(reports.classify(.window(3), receivedAt: t0 + .milliseconds(11), onShownWorkspace: false, concealed: true,
                             miss: miss, keyLeft: .stayed) == .follow(3))
    #expect(reports.miss(.window(7), app: 200, repeated: true, receivedAt: t0 + .milliseconds(12)) == .none)
}

@Test func aClickOnAWindowRecoveryShowedIsFollowed() {
    var reports = FocusReports()
    #expect(reports.classify(.window(4), receivedAt: t0 + .milliseconds(11), onShownWorkspace: false, concealed: false,
                             recovered: true, keyLeft: .unknown) == .undecided)
    #expect(reports.classify(.window(4), receivedAt: t0 + .milliseconds(11), onShownWorkspace: false, concealed: false,
                             recovered: true, keyLeft: .stayed) == .follow(4))
    #expect(reports.classify(.window(4), receivedAt: t0 + .milliseconds(12), onShownWorkspace: false, concealed: false,
                             keyLeft: .stayed) == .reassert)
}

@Test func aFullscreenSpaceIsOnScreenWhileItsWindowOrItsAppsPanelIsKey() {
    let fullscreen: [WindowID: Int32] = [5: 100]
    #expect(showsFullscreenSpace(key: .window(5), keyManaged: true, keyApp: 100, fullscreen: fullscreen))
    #expect(showsFullscreenSpace(key: .window(9), keyManaged: false, keyApp: 100, fullscreen: fullscreen))
    #expect(!showsFullscreenSpace(key: .window(6), keyManaged: true, keyApp: 100, fullscreen: fullscreen))
    #expect(!showsFullscreenSpace(key: .window(9), keyManaged: false, keyApp: 200, fullscreen: fullscreen))
    #expect(!showsFullscreenSpace(key: .noWindow, keyManaged: false, keyApp: nil, fullscreen: fullscreen))
}

@Test func anEchoIsKnownBeforeItIsClassified() {
    var reports = FocusReports()
    reports.focusRequested(.window(3), app: 100, at: t0 + .milliseconds(10))
    #expect(reports.isEcho(.window(3), receivedAt: t0 + .milliseconds(11)))
    #expect(!reports.isEcho(.window(3), receivedAt: t0 + .milliseconds(9)))
    #expect(!reports.isEcho(.window(4), receivedAt: t0 + .milliseconds(11)))
    #expect(reports.isEcho(.window(3), receivedAt: t0 + .milliseconds(11)))   // asking consumes nothing
}

@Test func thePublicPathsChoiceAnswersItsRequest() {
    var reports = FocusReports()
    reports.focusRequested(.window(1), app: 7, at: t0 + .milliseconds(10), publicly: true)
    #expect(reports.classify(.window(2), receivedAt: t0 + .milliseconds(11), onShownWorkspace: true, concealed: false, keyLeft: .stayed) == .adopt(2))
    reports.answered(by: 7, receivedAt: t0 + .milliseconds(11))
    #expect(reports.classify(.window(1), receivedAt: t0 + .milliseconds(12), onShownWorkspace: true, concealed: false, keyLeft: .stayed) == .adopt(1))
}

@Test func anotherWindowOfTheAppLeavesAPrivateRequestExpected() {   // change 6
    var reports = FocusReports()
    reports.focusRequested(.window(1), app: 7, at: t0 + .milliseconds(10))
    #expect(reports.classify(.window(2), receivedAt: t0 + .milliseconds(11), onShownWorkspace: true, concealed: false, keyLeft: .stayed) == .adopt(2))
    reports.answered(by: 7, receivedAt: t0 + .milliseconds(11))
    #expect(reports.classify(.window(1), receivedAt: t0 + .milliseconds(12), onShownWorkspace: true, concealed: false, keyLeft: .stayed) == .echo)
}

@Test func onlyTheNamedAppAnswersAPublicRequest() {
    var reports = FocusReports()
    reports.focusRequested(.window(1), app: 7, at: t0 + .milliseconds(10), publicly: true)
    reports.answered(by: 8, receivedAt: t0 + .milliseconds(11))
    reports.answered(by: 7, receivedAt: t0 + .milliseconds(9))
    #expect(reports.classify(.window(1), receivedAt: t0 + .milliseconds(12), onShownWorkspace: true, concealed: false, keyLeft: .stayed) == .echo)
}

@Test func forgottenRequestsSwallowNoReport() {
    var reports = FocusReports()
    reports.focusRequested(.window(1), app: nil, at: t0 + .milliseconds(10))
    reports.forgetRequests()
    #expect(reports.classify(.window(1), receivedAt: t0 + .milliseconds(20), onShownWorkspace: true, concealed: false, keyLeft: .stayed) == .adopt(1))
}

@Test func aBackgroundReportConsumesOnlyAnEcho() {
    var reports = FocusReports()
    reports.focusRequested(.window(1), app: nil, at: t0 + .milliseconds(10))
    let other = reports.consumeEcho(.window(2), receivedAt: t0 + .milliseconds(11))
    let echo = reports.consumeEcho(.window(1), receivedAt: t0 + .milliseconds(12))
    #expect(!other && echo)
    #expect(reports.classify(.window(1), receivedAt: t0 + .milliseconds(13), onShownWorkspace: true, concealed: false, keyLeft: .stayed) == .adopt(1))
}

@Test func aBackgroundEchoOfTheRetriedWindowEndsTheRetry() {
    var reports = FocusReports()
    reports.focusRequested(.window(1), app: 7, at: t0 + .milliseconds(10))
    #expect(reports.miss(.window(2), app: 7, repeated: true, receivedAt: t0 + .milliseconds(11)) == .retry)
    reports.focusRequested(.window(1), app: 7, at: t0 + .milliseconds(12))
    let echo = reports.consumeEcho(.window(1), receivedAt: t0 + .milliseconds(13))
    #expect(echo)
    reports.focusRequested(.window(1), app: 7, at: t0 + .milliseconds(20))
    #expect(reports.miss(.window(2), app: 7, repeated: true, receivedAt: t0 + .milliseconds(21)) == .retry)
}

@Test func forgettingRequestsEndsTheRetry() {
    var reports = FocusReports()
    reports.focusRequested(.window(1), app: 7, at: t0 + .milliseconds(10))
    #expect(reports.miss(.window(2), app: 7, repeated: true, receivedAt: t0 + .milliseconds(11)) == .retry)
    reports.forgetRequests()
    reports.focusRequested(.window(1), app: 7, at: t0 + .milliseconds(20))
    #expect(reports.miss(.window(2), app: 7, repeated: true, receivedAt: t0 + .milliseconds(21)) == .retry)
}

@Test func onlyAVerdictThatDependsOnTheDepartureReadsIt() {
    var reports = FocusReports()
    var reads = 0
    func departure(_ answer: Departure) -> Departure { reads += 1; return answer }
    reports.focusRequested(.window(1), app: nil, at: t0 + .milliseconds(10))
    #expect(reports.classify(.window(1), receivedAt: t0 + .milliseconds(11), onShownWorkspace: true, concealed: false, keyLeft: departure(.left)) == .echo)
    #expect(reports.classify(.window(2), receivedAt: t0 + .milliseconds(12), onShownWorkspace: true, concealed: false, keyLeft: departure(.left)) == .adopt(2))
    #expect(reads == 0)
    #expect(reports.classify(.window(3), receivedAt: t0 + .milliseconds(13), onShownWorkspace: false, concealed: true, keyLeft: departure(.left)) == .reassert)
    #expect(reports.classify(.noWindow, receivedAt: t0 + .milliseconds(14), onShownWorkspace: false, concealed: false, keyLeft: departure(.left)) == .reassert)
    #expect(reads == 2)
}

@Test func admissionFollowsOnlyAWindowItsAppKeyedSinceLaunch() {
    func decide(keyed: Bool = true, shown: Bool = false, parked: Bool = false, atLaunch: Bool = false,
                locked: Bool = false) -> AdmissionFocus {
        AdmissionFocus.decide(keyed: keyed, shown: shown, parked: parked, atLaunch: atLaunch, locked: locked)
    }
    #expect(decide() == .placedHidden)
    #expect(decide(keyed: false) == .placedHidden)
    #expect(decide(shown: true) == .adopt)
    #expect(decide(shown: true, atLaunch: true) == .adopt)
    #expect(decide(keyed: false, shown: true) == .awaitKey)
    #expect(decide(atLaunch: true) == .none)
    #expect(decide(keyed: false, shown: true, atLaunch: true) == .none)
    #expect(decide(parked: true) == .none)
    #expect(decide(keyed: false, shown: true, parked: true) == .none)
    #expect(decide(locked: true) == .none)
    #expect(decide(keyed: false, shown: true, locked: true) == .none)
}

@Test func aRepeatOfTheLastKeyWindowHasTheWindowBeforeIt() {   // change 24
    // The activation read after a notification repeats its window, and must find the same
    // window key before it, or Kosmos follows macOS's re-key.
    var keys = KeyHistory()
    _ = keys.heard(.window(2))
    #expect(keys.heard(.window(1)) == .window(2))
    #expect(keys.heard(.window(1)) == .window(2))
    #expect(keys.heard(.window(3)) == .window(1))
    #expect(keys.key == .window(3))
    #expect(keys.heard(.noWindow) == .window(3))
    #expect(keys.heard(.noWindow) == .noWindow)
}

@Test func aHeldReportIsDecidedOnceByItsGrace() {
    var held = HeldReport<String>()
    let first = held.hold("Ghostty", of: .window(3))
    #expect(held.holds(.window(3), repeated: true))
    #expect(!held.holds(.window(3), repeated: false))
    #expect(held.expire(first) == "Ghostty")
    #expect(held.expire(first) == nil)
}

@Test func aReplacedOrEndedHoldIsNotDecidedByAnOldGrace() {
    var held = HeldReport<String>()
    let first = held.hold("Ghostty", of: .window(3))
    let second = held.hold("Helium", of: .window(4))
    #expect(held.expire(first) == nil)
    #expect(held.report == "Helium")
    #expect(held.end() == "Helium")
    #expect(held.expire(second) == nil)
    #expect(!held.holds(.window(4), repeated: true))
}
