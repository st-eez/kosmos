import Testing
@testable import KosmosCore

// Each test replays a counterexample TLC found in tla/Kosmos.tla (tla/README.md, "Design
// changes found by the model").

@Test func ownRequestComesBackAsAnEcho() {
    var reports = FocusReports<Int>()
    reports.focusRequested(.window(1), app: nil, at: 10)
    #expect(reports.classify(.window(1), receivedAt: 11, onShownWorkspace: true, concealed: false, keyLeft: .stayed) == .echo)
    // Consumed: the same report again is the user's.
    #expect(reports.classify(.window(1), receivedAt: 12, onShownWorkspace: true, concealed: false, keyLeft: .stayed) == .adopt(1))
}

@Test func commandTabReportedAfterANewerCommandIsStale() {   // change 1
    var reports = FocusReports<Int>()
    reports.commandExecuted(receivedAt: 20)
    #expect(reports.classify(.window(3), receivedAt: 15, onShownWorkspace: false, concealed: true, keyLeft: .stayed) == .reassert)
}

@Test func anotherWindowOfTheIntendedAppIsNotAnEcho() {      // change 4
    var reports = FocusReports<Int>()
    reports.focusRequested(.window(1), app: nil, at: 10)
    #expect(reports.classify(.window(3), receivedAt: 11, onShownWorkspace: false, concealed: true, keyLeft: .stayed) == .follow(3))
}

@Test func reportReceivedBeforeTheRequestIsNotItsEcho() {    // change 5
    var reports = FocusReports<Int>()
    // The user clicked w3 at 9; Kosmos requested w3 at 10 before the click was reported.
    reports.focusRequested(.window(3), app: nil, at: 10)
    #expect(reports.classify(.window(3), receivedAt: 9, onShownWorkspace: true, concealed: false, keyLeft: .stayed) == .adopt(3))
    #expect(reports.classify(.window(3), receivedAt: 11, onShownWorkspace: true, concealed: false, keyLeft: .stayed) == .echo)
}

@Test func foreignReportKeepsExpectations() {                // change 6
    var reports = FocusReports<Int>()
    reports.focusRequested(.window(1), app: nil, at: 10)
    // The user's Command-Tab lands first, then Kosmos's late request comes back.
    #expect(reports.classify(.window(2), receivedAt: 11, onShownWorkspace: true, concealed: false, keyLeft: .stayed) == .adopt(2))
    #expect(reports.classify(.window(1), receivedAt: 12, onShownWorkspace: true, concealed: false, keyLeft: .stayed) == .echo)
}

@Test func visibleWindowOfAnotherWorkspaceIsNotFollowed() {  // change 7
    var reports = FocusReports<Int>()
    #expect(reports.classify(.window(5), receivedAt: 11, onShownWorkspace: false, concealed: false, keyLeft: .stayed) == .reassert)
}

@Test func laterEchoDropsEarlierExpectations() {
    var reports = FocusReports<Int>()
    reports.focusRequested(.window(1), app: nil, at: 10)
    reports.focusRequested(.window(2), app: nil, at: 11)
    #expect(reports.classify(.window(2), receivedAt: 12, onShownWorkspace: true, concealed: false, keyLeft: .stayed) == .echo)
    #expect(reports.classify(.window(1), receivedAt: 13, onShownWorkspace: true, concealed: false, keyLeft: .stayed) == .adopt(1))
}

@Test func emptyWorkspaceFocusIsAnEchoAndOtherwiseIgnored() {
    var reports = FocusReports<Int>()
    reports.focusRequested(.none, app: nil, at: 10)
    #expect(reports.classify(.none, receivedAt: 11, onShownWorkspace: false, concealed: false, keyLeft: .stayed) == .echo)
    #expect(reports.classify(.none, receivedAt: 12, onShownWorkspace: false, concealed: false, keyLeft: .stayed) == .ignore)
}

@Test func droppedRequestDoesNotSwallowAUserReport() {
    var reports = FocusReports<Int>()
    reports.focusRequested(.window(1), app: nil, at: 10)
    reports.requestDropped(.window(1), at: 10)
    #expect(reports.classify(.window(1), receivedAt: 11, onShownWorkspace: true, concealed: false, keyLeft: .stayed) == .adopt(1))
}

// Change 8: the key window leaves (it closes or minimizes, or its app hides), and macOS
// keys another window itself.

@Test func reKeyOntoAHiddenWindowAfterTheKeyWindowLeavesIsNotFollowed() {
    var reports = FocusReports<Int>()
    // Command-H on the only window of workspace 2; macOS keys Ghostty, concealed on 1.
    #expect(reports.classify(.window(3), receivedAt: 11, onShownWorkspace: false, concealed: true, keyLeft: .left) == .reassert)
}

@Test func commandTabSoonAfterAHideIsStillFollowed() {
    var reports = FocusReports<Int>()
    #expect(reports.classify(.window(2), receivedAt: 11, onShownWorkspace: true, concealed: false, keyLeft: .left) == .adopt(2))
    // The window key before the Command-Tab is the one macOS keyed, still on screen, which
    // no departure names: the report waits for the grace, then follows.
    #expect(reports.classify(.window(3), receivedAt: 12, onShownWorkspace: false, concealed: true, keyLeft: .unknown) == .undecided)
    #expect(reports.classify(.window(3), receivedAt: 12, onShownWorkspace: false, concealed: true, keyLeft: .stayed) == .follow(3))
}

@Test func noKeyWindowAfterTheKeyWindowLeavesFocusesTheWorkspaceAgain() {
    var reports = FocusReports<Int>()
    #expect(reports.classify(.none, receivedAt: 11, onShownWorkspace: false, concealed: false, keyLeft: .left) == .reassert)
}

@Test func ownRequestStillComesBackAsAnEchoAfterTheKeyWindowLeaves() {
    var reports = FocusReports<Int>()
    reports.focusRequested(.window(2), app: nil, at: 10)
    #expect(reports.classify(.window(2), receivedAt: 11, onShownWorkspace: true, concealed: false, keyLeft: .left) == .echo)
}

// Change 10: a window returns (unminimized, its app unhidden, out of native fullscreen),
// and a command comes before Kosmos handles the return.

@Test func aReturnReceivedBeforeTheLatestCommandIsStale() {
    var reports = FocusReports<Int>()
    #expect(!reports.isStale(10))   // no command yet
    reports.commandExecuted(receivedAt: 12)
    #expect(reports.isStale(11))
    #expect(!reports.isStale(12))
    #expect(!reports.isStale(13))
}

// Change 11: WindowServer shows a hidden app's window for a moment after macOS keyed the
// next window, so the departure can be unknown when the report arrives.

@Test func aReportThatDependsOnAnUnknownDepartureIsHeld() {
    var reports = FocusReports<Int>()
    // Command-H on the only window of workspace 2, reported before the hide: macOS keyed
    // Ghostty, concealed on 1.
    #expect(reports.classify(.window(3), receivedAt: 11, onShownWorkspace: false, concealed: true, keyLeft: .unknown) == .undecided)
    // No key window is not held: the departure focuses when it comes.
    #expect(reports.classify(.none, receivedAt: 11, onShownWorkspace: false, concealed: false, keyLeft: .unknown) == .ignore)
    // Classified again once the departure is known, or the grace ends.
    #expect(reports.classify(.window(3), receivedAt: 11, onShownWorkspace: false, concealed: true, keyLeft: .left) == .reassert)
    #expect(reports.classify(.window(3), receivedAt: 11, onShownWorkspace: false, concealed: true, keyLeft: .stayed) == .follow(3))
}

@Test func aReportThatDoesNotDependOnTheDepartureIsNotHeld() {
    var reports = FocusReports<Int>()
    reports.focusRequested(.window(2), app: nil, at: 10)
    #expect(reports.classify(.window(2), receivedAt: 11, onShownWorkspace: true, concealed: false, keyLeft: .unknown) == .echo)
    #expect(reports.classify(.window(1), receivedAt: 12, onShownWorkspace: true, concealed: false, keyLeft: .unknown) == .adopt(1))
    #expect(reports.classify(.window(5), receivedAt: 13, onShownWorkspace: false, concealed: false, keyLeft: .unknown) == .reassert)
    reports.commandExecuted(receivedAt: 20)
    #expect(reports.classify(.window(3), receivedAt: 14, onShownWorkspace: false, concealed: true, keyLeft: .unknown) == .reassert)
}

// Change 12: a focus request of Kosmos's misses. Fronting another window of the app that
// is already key leaves that app's key window, which the app reports again.

@Test func aRepeatOfAConcealedKeyWindowDuringOurRequestToItsAppIsAMiss() {
    var reports = FocusReports<Int>()
    // Kosmos switched to 1 and requested Ghostty's 86737; Ghostty kept 90919, concealed on 3
    // by the switch, and reported it again.
    reports.focusRequested(.window(86737), app: 100, at: 10)
    let miss = reports.miss(.window(90919), app: 100, repeated: true, receivedAt: 11)
    #expect(miss == .retry)
    #expect(reports.classify(.window(90919), receivedAt: 11, onShownWorkspace: false, concealed: true,
                             miss: miss, keyLeft: .stayed) == .reassert)
}

@Test func aMissIsRetriedOnceThenTheKeyWindowIsAccepted() {
    var reports = FocusReports<Int>()
    reports.focusRequested(.window(86737), app: 100, at: 10)
    #expect(reports.miss(.window(90919), app: 100, repeated: true, receivedAt: 11) == .retry)
    reports.focusRequested(.window(86737), app: 100, at: 12)   // the retry
    let second = reports.miss(.window(90919), app: 100, repeated: true, receivedAt: 13)
    #expect(second == .accept)
    #expect(reports.classify(.window(90919), receivedAt: 13, onShownWorkspace: false, concealed: true,
                             miss: second, keyLeft: .stayed) == .ignore)
    // A new intent may retry again.
    reports.focusRequested(.window(5), app: 100, at: 14)
    #expect(reports.miss(.window(90919), app: 100, repeated: true, receivedAt: 15) == .retry)
}

@Test func aMissOnTheShownWorkspaceIsNotTheUsersChoiceEither() {
    var reports = FocusReports<Int>()
    reports.focusRequested(.window(2), app: 100, at: 10)
    let miss = reports.miss(.window(1), app: 100, repeated: true, receivedAt: 11)
    #expect(reports.classify(.window(1), receivedAt: 11, onShownWorkspace: true, concealed: false,
                             miss: miss, keyLeft: .stayed) == .reassert)
    reports.focusRequested(.window(2), app: 100, at: 12)
    let accepted = reports.miss(.window(1), app: 100, repeated: true, receivedAt: 13)
    #expect(reports.classify(.window(1), receivedAt: 13, onShownWorkspace: true, concealed: false,
                             miss: accepted, keyLeft: .stayed) == .adopt(1))
}

@Test func aMissedRequestNoLongerTakesAReportOfItsWindowForItsEcho() {
    var reports = FocusReports<Int>()
    reports.focusRequested(.window(1), app: 100, at: 10)
    reports.focusRequested(.window(1), app: 100, at: 11)   // a second request, performed later
    #expect(reports.miss(.window(3), app: 100, repeated: true, receivedAt: 12) == .retry)
    // The later request still comes back as an echo; once it did, the user's report of 1 is
    // the user's.
    #expect(reports.classify(.window(1), receivedAt: 13, onShownWorkspace: true, concealed: false, keyLeft: .stayed) == .echo)
    #expect(reports.classify(.window(1), receivedAt: 14, onShownWorkspace: false, concealed: true, keyLeft: .stayed) == .follow(1))
}

@Test func anEchoOfTheRaiseAfterAKeyRecordIsNoMiss() {
    var reports = FocusReports<Int>()
    // The key record keyed window 1 of app 100, the worker raised it after, and a request for
    // the app's window 2 followed. The app reported 1 again for the raise.
    reports.focusRequested(.window(1), app: 100, at: 10)
    #expect(reports.classify(.window(1), receivedAt: 11, onShownWorkspace: true, concealed: false, keyLeft: .stayed) == .echo)
    reports.focusRequested(.window(1), app: 100, at: 12)   // the raise
    reports.focusRequested(.window(2), app: 100, at: 13)
    #expect(reports.miss(.window(1), app: 100, repeated: true, receivedAt: 14) == .none)
    #expect(reports.classify(.window(1), receivedAt: 14, onShownWorkspace: true, concealed: false, keyLeft: .stayed) == .echo)
    #expect(reports.classify(.window(2), receivedAt: 15, onShownWorkspace: true, concealed: false, keyLeft: .stayed) == .echo)
}

@Test func openingAConcealedWindowOfTheRequestedAppIsTheUsersChoice() {
    var reports = FocusReports<Int>()
    // `open a.pdf` fronts Preview's concealed window 3 while Kosmos's request for Preview's
    // window 1 is on its way: a key change, not a repeat, so it is followed.
    reports.focusRequested(.window(1), app: 100, at: 10)
    let miss = reports.miss(.window(3), app: 100, repeated: false, receivedAt: 11)
    #expect(miss == .none)
    #expect(reports.classify(.window(3), receivedAt: 11, onShownWorkspace: false, concealed: true,
                             miss: miss, keyLeft: .stayed) == .follow(3))
    // A repeat with no request to that app awaiting its echo is no miss either.
    #expect(reports.miss(.window(7), app: 200, repeated: true, receivedAt: 12) == .none)
}

@Test func aClickOnAWindowRecoveryShowedIsFollowed() {
    var reports = FocusReports<Int>()
    // A batch failed and recovery showed every workspace's windows.
    #expect(reports.classify(.window(4), receivedAt: 11, onShownWorkspace: false, concealed: false,
                             recovered: true, keyLeft: .unknown) == .undecided)
    #expect(reports.classify(.window(4), receivedAt: 11, onShownWorkspace: false, concealed: false,
                             recovered: true, keyLeft: .stayed) == .follow(4))
    // Otherwise a visible window of another workspace is key only during a switch.
    #expect(reports.classify(.window(4), receivedAt: 12, onShownWorkspace: false, concealed: false,
                             keyLeft: .stayed) == .reassert)
}

@Test func aFullscreenSpaceIsOnScreenWhileItsWindowOrItsAppsPanelIsKey() {
    let fullscreen: [WindowID: Int32] = [5: 100]   // window 5 of app 100
    #expect(showsFullscreenSpace(key: .window(5), keyManaged: true, keyApp: 100, fullscreen: fullscreen))
    // A panel or dialog of the fullscreen app, which Kosmos does not manage.
    #expect(showsFullscreenSpace(key: .window(9), keyManaged: false, keyApp: 100, fullscreen: fullscreen))
    // A managed desktop window of the same app, or another app's panel: the desktop.
    #expect(!showsFullscreenSpace(key: .window(6), keyManaged: true, keyApp: 100, fullscreen: fullscreen))
    #expect(!showsFullscreenSpace(key: .window(9), keyManaged: false, keyApp: 200, fullscreen: fullscreen))
    #expect(!showsFullscreenSpace(key: KeyWindow.none, keyManaged: false, keyApp: nil, fullscreen: fullscreen))
}

@Test func anEchoIsKnownBeforeItIsClassified() {
    var reports = FocusReports<Int>()
    reports.focusRequested(.window(3), app: 100, at: 10)
    #expect(reports.isEcho(.window(3), receivedAt: 11))
    #expect(!reports.isEcho(.window(3), receivedAt: 9))   // received before the request
    #expect(!reports.isEcho(.window(4), receivedAt: 11))
    #expect(reports.isEcho(.window(3), receivedAt: 11))   // asking consumes nothing
}

@Test func thePublicPathsChoiceAnswersItsRequest() {
    var reports = FocusReports<Int>()
    reports.focusRequested(.window(1), app: 7, at: 10, publicly: true)
    // App 7 keyed window 2 of its own choosing.
    #expect(reports.classify(.window(2), receivedAt: 11, onShownWorkspace: true, concealed: false, keyLeft: .stayed) == .adopt(2))
    reports.publicRequestsAnswered(by: 7, receivedAt: 11)
    // The user's click on window 1 is theirs, not the request's echo.
    #expect(reports.classify(.window(1), receivedAt: 12, onShownWorkspace: true, concealed: false, keyLeft: .stayed) == .adopt(1))
}

@Test func anotherWindowOfTheAppLeavesAPrivateRequestExpected() {   // change 6
    var reports = FocusReports<Int>()
    reports.focusRequested(.window(1), app: 7, at: 10)
    #expect(reports.classify(.window(2), receivedAt: 11, onShownWorkspace: true, concealed: false, keyLeft: .stayed) == .adopt(2))
    reports.publicRequestsAnswered(by: 7, receivedAt: 11)
    #expect(reports.classify(.window(1), receivedAt: 12, onShownWorkspace: true, concealed: false, keyLeft: .stayed) == .echo)
}

@Test func onlyTheNamedAppAnswersAPublicRequest() {
    var reports = FocusReports<Int>()
    reports.focusRequested(.window(1), app: 7, at: 10, publicly: true)
    reports.publicRequestsAnswered(by: 8, receivedAt: 11)
    // A report received before the request answers nothing either.
    reports.publicRequestsAnswered(by: 7, receivedAt: 9)
    #expect(reports.classify(.window(1), receivedAt: 12, onShownWorkspace: true, concealed: false, keyLeft: .stayed) == .echo)
}

@Test func forgottenRequestsSwallowNoReport() {
    // An echo that arrived while the session was locked was never classified.
    var reports = FocusReports<Int>()
    reports.focusRequested(.window(1), app: nil, at: 10)
    reports.forgetRequests()
    #expect(reports.classify(.window(1), receivedAt: 20, onShownWorkspace: true, concealed: false, keyLeft: .stayed) == .adopt(1))
}

@Test func aBackgroundReportConsumesOnlyAnEcho() {
    var reports = FocusReports<Int>()
    reports.focusRequested(.window(1), app: nil, at: 10)
    let other = reports.consumeEcho(.window(2), receivedAt: 11)
    let echo = reports.consumeEcho(.window(1), receivedAt: 12)
    #expect(!other && echo)
    // Consumed: a later report of window 1 is the user's.
    #expect(reports.classify(.window(1), receivedAt: 13, onShownWorkspace: true, concealed: false, keyLeft: .stayed) == .adopt(1))
}

@Test func aBackgroundEchoOfTheRetriedWindowEndsTheRetry() {
    var reports = FocusReports<Int>()
    reports.focusRequested(.window(1), app: 7, at: 10)
    #expect(reports.miss(.window(2), app: 7, repeated: true, receivedAt: 11) == .retry)
    reports.focusRequested(.window(1), app: 7, at: 12)
    let echo = reports.consumeEcho(.window(1), receivedAt: 13)
    #expect(echo)
    // The retry keyed window 1, so a later miss of it is retried again.
    reports.focusRequested(.window(1), app: 7, at: 20)
    #expect(reports.miss(.window(2), app: 7, repeated: true, receivedAt: 21) == .retry)
}

@Test func forgettingRequestsEndsTheRetry() {
    var reports = FocusReports<Int>()
    reports.focusRequested(.window(1), app: 7, at: 10)
    #expect(reports.miss(.window(2), app: 7, repeated: true, receivedAt: 11) == .retry)
    reports.forgetRequests()
    reports.focusRequested(.window(1), app: 7, at: 20)
    #expect(reports.miss(.window(2), app: 7, repeated: true, receivedAt: 21) == .retry)
}

@Test func onlyAVerdictThatDependsOnTheDepartureReadsIt() {
    var reports = FocusReports<Int>()
    var reads = 0
    func departure(_ answer: Departure) -> Departure { reads += 1; return answer }
    reports.focusRequested(.window(1), app: nil, at: 10)
    #expect(reports.classify(.window(1), receivedAt: 11, onShownWorkspace: true, concealed: false, keyLeft: departure(.left)) == .echo)
    #expect(reports.classify(.window(2), receivedAt: 12, onShownWorkspace: true, concealed: false, keyLeft: departure(.left)) == .adopt(2))
    #expect(reads == 0)
    #expect(reports.classify(.window(3), receivedAt: 13, onShownWorkspace: false, concealed: true, keyLeft: departure(.left)) == .reassert)
    #expect(reports.classify(.none, receivedAt: 14, onShownWorkspace: false, concealed: false, keyLeft: departure(.left)) == .reassert)
    #expect(reads == 2)
}

@Test func admissionFollowsOnlyAWindowItsAppKeyedSinceLaunch() {
    func decide(keyed: Bool = true, shown: Bool = false, parked: Bool = false, atLaunch: Bool = false,
                locked: Bool = false) -> AdmissionFocus {
        AdmissionFocus.decide(keyed: keyed, shown: shown, parked: parked, atLaunch: atLaunch, locked: locked)
    }
    // Live, 2026-09-25: Chrome launched on workspace 8, and a rule put its first window on
    // workspace 4, which no display showed. Kosmos concealed the window and keyed Claude
    // again, so Steve pressed alt-4 himself. The report that waited for the place is decided
    // as one of a concealed window whose key window before it stayed, which follows.
    #expect(decide() == .placedHidden)
    // A window no report named, as one a background app opened: a report before its conceal
    // completes is decided the same way.
    #expect(decide(keyed: false) == .placedHidden)
    // On a shown workspace, as with a rule that names no workspace, it becomes the focus
    // there, at launch too.
    #expect(decide(shown: true) == .adopt)
    #expect(decide(shown: true, atLaunch: true) == .adopt)
    #expect(decide(keyed: false, shown: true) == .none)
    // Kosmos's launch sweep, a parked window and a locked session follow nothing.
    #expect(decide(atLaunch: true) == .none)
    #expect(decide(parked: true) == .none)
    #expect(decide(locked: true) == .none)
}
