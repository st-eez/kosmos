import Testing
@testable import KosmosCore

private func miss(_ misses: inout FocusMisses, at: ContinuousClock.Instant, reported: WindowID = 9) -> Bool {
    let tripped = misses.willRequest(5, pid: 1, at: at)
    misses.reported(.window(reported), pid: 1, receivedAt: at + .milliseconds(1), echo: false)
    return tripped
}

@Test func fiveWrongWindowsInARowTurnThePathOffAtTheNextRequest() {
    var misses = FocusMisses()
    for request in 0..<FocusMisses.limit {
        #expect(!miss(&misses, at: t0 + .milliseconds(request * 10)))
    }
    let tripped = misses.willRequest(5, pid: 1, at: t0 + .milliseconds(100))
    #expect(tripped)
}

@Test func aMissAndItsRetryCountOnce() {
    var misses = FocusMisses()
    for attempt in 0..<FocusMisses.limit {
        let request = misses.willRequest(5, pid: 1, at: t0 + .milliseconds(attempt * 10))
        misses.reported(.window(9), pid: 1, receivedAt: t0 + .milliseconds(attempt * 10 + 1), echo: false)
        let retry = misses.willRequest(5, pid: 1, at: t0 + .milliseconds(attempt * 10 + 2), retry: true)
        misses.reported(.window(9), pid: 1, receivedAt: t0 + .milliseconds(attempt * 10 + 3), echo: false)
        #expect(!request && !retry)
    }
    let tripped = misses.willRequest(5, pid: 1, at: t0 + .milliseconds(100))
    #expect(tripped)
}

@Test func anEchoClearsTheCount() {
    var misses = FocusMisses()
    for request in 0..<4 { _ = miss(&misses, at: t0 + .milliseconds(request * 10)) }
    _ = misses.willRequest(5, pid: 1, at: t0 + .milliseconds(50))
    misses.reported(.window(5), pid: 1, receivedAt: t0 + .milliseconds(51), echo: true)
    #expect(misses.inARow == 0)
    for request in 6..<10 { #expect(!miss(&misses, at: t0 + .milliseconds(request * 10))) }
}

@Test func aLateEchoAfterAStaleActivationReadIsAHit() {
    var misses = FocusMisses()
    for request in 0..<10 {
        _ = misses.willRequest(5, pid: 1, at: t0 + .milliseconds(request * 10))
        misses.reported(.window(9), pid: 1, receivedAt: t0 + .milliseconds(request * 10 + 1), echo: false)
        misses.reported(.window(5), pid: 1, receivedAt: t0 + .milliseconds(request * 10 + 2), echo: true)
    }
    let tripped = misses.willRequest(5, pid: 1, at: t0 + .milliseconds(200))
    #expect(!tripped)
    #expect(misses.inARow == 0)
}

@Test func echoesArrivingAfterTheNextRequestKeepTheCountDown() {
    var misses = FocusMisses()
    var tripped = false
    for request in 1..<20 {
        let window = WindowID(request)
        tripped = misses.willRequest(window, pid: 1, at: t0 + .milliseconds(request * 10)) || tripped
        misses.reported(.window(window - 1), pid: 1, receivedAt: t0 + .milliseconds(request * 10 + 1), echo: true)
        misses.reported(.window(window - 1), pid: 1, receivedAt: t0 + .milliseconds(request * 10 + 2), echo: false)
    }
    #expect(!tripped)
}

@Test func anotherAppsReportIsNotAMiss() {
    var misses = FocusMisses()
    for request in 0..<10 {
        _ = misses.willRequest(5, pid: 1, at: t0 + .milliseconds(request * 10))
        misses.reported(.window(9), pid: 2, receivedAt: t0 + .milliseconds(request * 10 + 1), echo: false)
    }
    #expect(misses.inARow == 0)
}

@Test func aReportOfTheRequestedWindowIsNeverAMiss() {
    // The raise can report the window before the key record lands, and the activation read
    // reports it again after that report was taken as the echo.
    var misses = FocusMisses()
    var tripped = false
    for request in 0..<10 {
        tripped = misses.willRequest(5, pid: 1, at: t0 + .milliseconds(request * 10)) || tripped
        misses.reported(.window(5), pid: 1, receivedAt: t0 + .milliseconds(request * 10 + 1), echo: false)
    }
    tripped = misses.willRequest(5, pid: 1, at: t0 + .milliseconds(100)) || tripped
    #expect(!tripped)
    #expect(misses.inARow == 0)
}

@Test func aReportReceivedBeforeTheRequestIsNotItsReadBack() {
    var misses = FocusMisses()
    for request in 1...10 {
        _ = misses.willRequest(5, pid: 1, at: t0 + .milliseconds(request * 10))
        misses.reported(.window(9), pid: 1, receivedAt: t0 + .milliseconds(request * 10 - 1), echo: false)
    }
    #expect(misses.inARow == 0)
}

@Test func aDroppedRequestIsNotJudged() {
    var misses = FocusMisses()
    for request in 0..<10 {
        _ = misses.willRequest(5, pid: 1, at: t0 + .milliseconds(request * 10))
        misses.requestDropped(at: t0 + .milliseconds(request * 10))
        misses.reported(.window(9), pid: 1, receivedAt: t0 + .milliseconds(request * 10 + 1), echo: false)
    }
    #expect(misses.inARow == 0)
}

@Test func silenceAndNoKeyWindowAreNotMisses() {
    var misses = FocusMisses()
    for request in 0..<10 {
        _ = misses.willRequest(5, pid: 1, at: t0 + .milliseconds(request * 10))
        if request.isMultiple(of: 2) { misses.reported(.noWindow, pid: 1, receivedAt: t0 + .milliseconds(request * 10 + 1), echo: false) }
    }
    #expect(misses.inARow == 0)
}

@Test func aClickOnAnotherWindowAfterTheRequestedOneWasKeyIsNoMiss() {
    // A background report consumed the echo of window 5.
    var misses = FocusMisses()
    for request in 0..<10 {
        _ = misses.willRequest(5, pid: 1, at: t0 + .milliseconds(request * 10))
        misses.reported(.window(5), pid: 1, receivedAt: t0 + .milliseconds(request * 10 + 1), echo: false)
        misses.reported(.window(9), pid: 1, receivedAt: t0 + .milliseconds(request * 10 + 2), echo: false)
    }
    let tripped = misses.willRequest(5, pid: 1, at: t0 + .milliseconds(100))
    #expect(!tripped && misses.inARow == 0)
}
