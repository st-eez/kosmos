import Testing
@testable import KosmosCore

// Each test replays a counterexample TLC found in tla/Kosmos.tla (tla/README.md, "Design
// changes found by the model").

@Test func ownRequestComesBackAsAnEcho() {
    var reports = FocusReports<Int>()
    reports.focusRequested(.window(1), at: 10)
    #expect(reports.classify(.window(1), receivedAt: 11, onCurrentWorkspace: true, wasHidden: false) == .echo)
    // Consumed: the same report again is the user's.
    #expect(reports.classify(.window(1), receivedAt: 12, onCurrentWorkspace: true, wasHidden: false) == .adopt(1))
}

@Test func commandTabReportedAfterANewerCommandIsStale() {   // change 1
    var reports = FocusReports<Int>()
    reports.commandExecuted(receivedAt: 20)
    #expect(reports.classify(.window(3), receivedAt: 15, onCurrentWorkspace: false, wasHidden: true) == .reassert)
}

@Test func anotherWindowOfTheIntendedAppIsNotAnEcho() {      // change 4
    var reports = FocusReports<Int>()
    reports.focusRequested(.window(1), at: 10)
    #expect(reports.classify(.window(3), receivedAt: 11, onCurrentWorkspace: false, wasHidden: true) == .follow(3))
}

@Test func reportReceivedBeforeTheRequestIsNotItsEcho() {    // change 5
    var reports = FocusReports<Int>()
    // The user clicked w3 at 9; Kosmos requested w3 at 10 before the click was reported.
    reports.focusRequested(.window(3), at: 10)
    #expect(reports.classify(.window(3), receivedAt: 9, onCurrentWorkspace: true, wasHidden: false) == .adopt(3))
    #expect(reports.classify(.window(3), receivedAt: 11, onCurrentWorkspace: true, wasHidden: false) == .echo)
}

@Test func foreignReportKeepsExpectations() {                // change 6
    var reports = FocusReports<Int>()
    reports.focusRequested(.window(1), at: 10)
    // The user's Command-Tab lands first, then Kosmos's late request comes back.
    #expect(reports.classify(.window(2), receivedAt: 11, onCurrentWorkspace: true, wasHidden: false) == .adopt(2))
    #expect(reports.classify(.window(1), receivedAt: 12, onCurrentWorkspace: true, wasHidden: false) == .echo)
}

@Test func visibleWindowOfAnotherWorkspaceIsNotFollowed() {  // change 7
    var reports = FocusReports<Int>()
    #expect(reports.classify(.window(5), receivedAt: 11, onCurrentWorkspace: false, wasHidden: false) == .reassert)
}

@Test func laterEchoDropsEarlierExpectations() {
    var reports = FocusReports<Int>()
    reports.focusRequested(.window(1), at: 10)
    reports.focusRequested(.window(2), at: 11)
    #expect(reports.classify(.window(2), receivedAt: 12, onCurrentWorkspace: true, wasHidden: false) == .echo)
    #expect(reports.classify(.window(1), receivedAt: 13, onCurrentWorkspace: true, wasHidden: false) == .adopt(1))
}

@Test func emptyWorkspaceFocusIsAnEchoAndOtherwiseIgnored() {
    var reports = FocusReports<Int>()
    reports.focusRequested(.none, at: 10)
    #expect(reports.classify(.none, receivedAt: 11, onCurrentWorkspace: false, wasHidden: false) == .echo)
    #expect(reports.classify(.none, receivedAt: 12, onCurrentWorkspace: false, wasHidden: false) == .ignore)
}

@Test func droppedRequestDoesNotSwallowAUserReport() {
    var reports = FocusReports<Int>()
    reports.focusRequested(.window(1), at: 10)
    reports.requestDropped(.window(1), at: 10)
    #expect(reports.classify(.window(1), receivedAt: 11, onCurrentWorkspace: true, wasHidden: false) == .adopt(1))
}

@Test func thePublicPathsChoiceAnswersItsRequest() {
    var reports = FocusReports<Int>()
    reports.focusRequested(.window(1), at: 10, publicIn: 7)
    // App 7 keyed window 2 of its own choosing.
    #expect(reports.classify(.window(2), receivedAt: 11, onCurrentWorkspace: true, wasHidden: false) == .adopt(2))
    reports.publicRequestsAnswered(by: 7, receivedAt: 11)
    // The user's click on window 1 is theirs, not the request's echo.
    #expect(reports.classify(.window(1), receivedAt: 12, onCurrentWorkspace: true, wasHidden: false) == .adopt(1))
}

@Test func anotherWindowOfTheAppLeavesAPrivateRequestExpected() {   // change 6
    var reports = FocusReports<Int>()
    reports.focusRequested(.window(1), at: 10)
    #expect(reports.classify(.window(2), receivedAt: 11, onCurrentWorkspace: true, wasHidden: false) == .adopt(2))
    reports.publicRequestsAnswered(by: 7, receivedAt: 11)
    #expect(reports.classify(.window(1), receivedAt: 12, onCurrentWorkspace: true, wasHidden: false) == .echo)
}

@Test func onlyTheNamedAppAnswersAPublicRequest() {
    var reports = FocusReports<Int>()
    reports.focusRequested(.window(1), at: 10, publicIn: 7)
    reports.publicRequestsAnswered(by: 8, receivedAt: 11)
    // A report received before the request answers nothing either.
    reports.publicRequestsAnswered(by: 7, receivedAt: 9)
    #expect(reports.classify(.window(1), receivedAt: 12, onCurrentWorkspace: true, wasHidden: false) == .echo)
}

@Test func forgottenRequestsSwallowNoReport() {
    // An echo that arrived while the session was locked was never classified.
    var reports = FocusReports<Int>()
    reports.focusRequested(.window(1), at: 10)
    reports.forgetRequests()
    #expect(reports.classify(.window(1), receivedAt: 20, onCurrentWorkspace: true, wasHidden: false) == .adopt(1))
}
