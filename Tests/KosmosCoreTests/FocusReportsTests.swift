import Testing
@testable import KosmosCore

// Each test replays a counterexample TLC found in tla/Kosmos.tla (tla/README.md, "Design
// changes found by the model").

@Test func ownRequestComesBackAsAnEcho() {
    var reports = FocusReports<Int>()
    reports.focusRequested(.window(1), at: 10)
    #expect(reports.classify(.window(1), receivedAt: 11, onCurrentWorkspace: true, reachable: false, keyLeft: .stayed) == .echo)
    // Consumed: the same report again is the user's.
    #expect(reports.classify(.window(1), receivedAt: 12, onCurrentWorkspace: true, reachable: false, keyLeft: .stayed) == .adopt(1))
}

@Test func commandTabReportedAfterANewerCommandIsStale() {   // change 1
    var reports = FocusReports<Int>()
    reports.commandExecuted(receivedAt: 20)
    #expect(reports.classify(.window(3), receivedAt: 15, onCurrentWorkspace: false, reachable: true, keyLeft: .stayed) == .reassert)
}

@Test func anotherWindowOfTheIntendedAppIsNotAnEcho() {      // change 4
    var reports = FocusReports<Int>()
    reports.focusRequested(.window(1), at: 10)
    #expect(reports.classify(.window(3), receivedAt: 11, onCurrentWorkspace: false, reachable: true, keyLeft: .stayed) == .follow(3))
}

@Test func reportReceivedBeforeTheRequestIsNotItsEcho() {    // change 5
    var reports = FocusReports<Int>()
    // The user clicked w3 at 9; Kosmos requested w3 at 10 before the click was reported.
    reports.focusRequested(.window(3), at: 10)
    #expect(reports.classify(.window(3), receivedAt: 9, onCurrentWorkspace: true, reachable: false, keyLeft: .stayed) == .adopt(3))
    #expect(reports.classify(.window(3), receivedAt: 11, onCurrentWorkspace: true, reachable: false, keyLeft: .stayed) == .echo)
}

@Test func foreignReportKeepsExpectations() {                // change 6
    var reports = FocusReports<Int>()
    reports.focusRequested(.window(1), at: 10)
    // The user's Command-Tab lands first, then Kosmos's late request comes back.
    #expect(reports.classify(.window(2), receivedAt: 11, onCurrentWorkspace: true, reachable: false, keyLeft: .stayed) == .adopt(2))
    #expect(reports.classify(.window(1), receivedAt: 12, onCurrentWorkspace: true, reachable: false, keyLeft: .stayed) == .echo)
}

@Test func visibleWindowOfAnotherWorkspaceIsNotFollowed() {  // change 7
    var reports = FocusReports<Int>()
    #expect(reports.classify(.window(5), receivedAt: 11, onCurrentWorkspace: false, reachable: false, keyLeft: .stayed) == .reassert)
}

@Test func laterEchoDropsEarlierExpectations() {
    var reports = FocusReports<Int>()
    reports.focusRequested(.window(1), at: 10)
    reports.focusRequested(.window(2), at: 11)
    #expect(reports.classify(.window(2), receivedAt: 12, onCurrentWorkspace: true, reachable: false, keyLeft: .stayed) == .echo)
    #expect(reports.classify(.window(1), receivedAt: 13, onCurrentWorkspace: true, reachable: false, keyLeft: .stayed) == .adopt(1))
}

@Test func emptyWorkspaceFocusIsAnEchoAndOtherwiseIgnored() {
    var reports = FocusReports<Int>()
    reports.focusRequested(.none, at: 10)
    #expect(reports.classify(.none, receivedAt: 11, onCurrentWorkspace: false, reachable: false, keyLeft: .stayed) == .echo)
    #expect(reports.classify(.none, receivedAt: 12, onCurrentWorkspace: false, reachable: false, keyLeft: .stayed) == .ignore)
}

@Test func droppedRequestDoesNotSwallowAUserReport() {
    var reports = FocusReports<Int>()
    reports.focusRequested(.window(1), at: 10)
    reports.requestDropped(.window(1), at: 10)
    #expect(reports.classify(.window(1), receivedAt: 11, onCurrentWorkspace: true, reachable: false, keyLeft: .stayed) == .adopt(1))
}

// Change 8: the key window leaves (it closes or minimizes, or its app hides), and macOS
// keys another window itself.

@Test func reKeyOntoAHiddenWindowAfterTheKeyWindowLeavesIsNotFollowed() {
    var reports = FocusReports<Int>()
    // Command-H on the only window of workspace 2; macOS keys Ghostty, concealed on 1.
    #expect(reports.classify(.window(3), receivedAt: 11, onCurrentWorkspace: false, reachable: true, keyLeft: .left) == .reassert)
}

@Test func commandTabSoonAfterAHideIsStillFollowed() {
    var reports = FocusReports<Int>()
    #expect(reports.classify(.window(2), receivedAt: 11, onCurrentWorkspace: true, reachable: false, keyLeft: .left) == .adopt(2))
    // The window key before the Command-Tab is the one macOS keyed, still on screen.
    #expect(reports.classify(.window(3), receivedAt: 12, onCurrentWorkspace: false, reachable: true, keyLeft: .stayed) == .follow(3))
}

@Test func noKeyWindowAfterTheKeyWindowLeavesFocusesTheWorkspaceAgain() {
    var reports = FocusReports<Int>()
    #expect(reports.classify(.none, receivedAt: 11, onCurrentWorkspace: false, reachable: false, keyLeft: .left) == .reassert)
}

@Test func ownRequestStillComesBackAsAnEchoAfterTheKeyWindowLeaves() {
    var reports = FocusReports<Int>()
    reports.focusRequested(.window(2), at: 10)
    #expect(reports.classify(.window(2), receivedAt: 11, onCurrentWorkspace: true, reachable: false, keyLeft: .left) == .echo)
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
    #expect(reports.classify(.window(3), receivedAt: 11, onCurrentWorkspace: false, reachable: true, keyLeft: .unknown) == .undecided)
    // No key window is not held: the departure focuses when it comes.
    #expect(reports.classify(.none, receivedAt: 11, onCurrentWorkspace: false, reachable: false, keyLeft: .unknown) == .ignore)
    // Classified again once the departure is known, or the grace ends.
    #expect(reports.classify(.window(3), receivedAt: 11, onCurrentWorkspace: false, reachable: true, keyLeft: .left) == .reassert)
    #expect(reports.classify(.window(3), receivedAt: 11, onCurrentWorkspace: false, reachable: true, keyLeft: .stayed) == .follow(3))
}

@Test func aReportThatDoesNotDependOnTheDepartureIsNotHeld() {
    var reports = FocusReports<Int>()
    reports.focusRequested(.window(2), at: 10)
    #expect(reports.classify(.window(2), receivedAt: 11, onCurrentWorkspace: true, reachable: false, keyLeft: .unknown) == .echo)
    #expect(reports.classify(.window(1), receivedAt: 12, onCurrentWorkspace: true, reachable: false, keyLeft: .unknown) == .adopt(1))
    #expect(reports.classify(.window(5), receivedAt: 13, onCurrentWorkspace: false, reachable: false, keyLeft: .unknown) == .reassert)
    reports.commandExecuted(receivedAt: 20)
    #expect(reports.classify(.window(3), receivedAt: 14, onCurrentWorkspace: false, reachable: true, keyLeft: .unknown) == .reassert)
}

// Change 12: a focus request of Kosmos's misses. Fronting another window of the app that
// is already key leaves that app's key window, which the app reports again.

@Test func aRepeatedReportOfAHiddenKeyWindowIsAMissNotACommandTab() {
    var reports = FocusReports<Int>()
    // Kosmos switched to 1 and requested Ghostty's 86737; Ghostty kept 90919, now concealed
    // on 3, and reported it again.
    reports.focusRequested(.window(86737), at: 10)
    #expect(reports.classify(.window(90919), receivedAt: 11, onCurrentWorkspace: false, reachable: true,
                             repeated: true, shownSibling: 86737, keyLeft: .stayed) == .reassert)
}

@Test func aHiddenWindowWhoseAppIsShownRedirectsToThatApp() {
    var reports = FocusReports<Int>()
    // Command-Tab to an app with a window on the shown workspace lands there, so a key
    // change to its hidden window is macOS's own.
    #expect(reports.classify(.window(3), receivedAt: 11, onCurrentWorkspace: false, reachable: true,
                             shownSibling: 1, keyLeft: .unknown) == .redirect(1))
    // With no window of the app shown, it is a Command-Tab.
    #expect(reports.classify(.window(3), receivedAt: 12, onCurrentWorkspace: false, reachable: true,
                             keyLeft: .stayed) == .follow(3))
}
