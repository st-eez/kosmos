import Testing
@testable import KosmosCore

/// A request for a window of app 1 at `at`, answered by app 1 reporting `reported`.
private func miss(_ misses: inout FocusMisses<Int>, at: Int, reported: UInt32 = 9) -> Bool {
    let tripped = misses.willRequest(pid: 1, at: at)
    misses.reported(.window(reported), pid: 1, receivedAt: at + 1, echo: false)
    return tripped
}

@Test func fiveWrongWindowsInARowTurnThePathOffAtTheNextRequest() {
    var misses = FocusMisses<Int>()
    for request in 0..<FocusMisses<Int>.limit {
        #expect(!miss(&misses, at: request * 10))
    }
    // The fifth miss is judged when the sixth request is made.
    let tripped = misses.willRequest(pid: 1, at: 100)
    #expect(tripped)
}

@Test func anEchoClearsTheCount() {
    var misses = FocusMisses<Int>()
    for request in 0..<4 { _ = miss(&misses, at: request * 10) }
    _ = misses.willRequest(pid: 1, at: 50)
    misses.reported(.window(5), pid: 1, receivedAt: 51, echo: true)
    #expect(misses.inARow == 0)
    for request in 6..<10 { #expect(!miss(&misses, at: request * 10)) }
}

@Test func aLateEchoAfterAStaleActivationReadIsAHit() {
    var misses = FocusMisses<Int>()
    for request in 0..<10 {
        // The activation read names the window that was key before; the key change follows.
        _ = misses.willRequest(pid: 1, at: request * 10)
        misses.reported(.window(9), pid: 1, receivedAt: request * 10 + 1, echo: false)
        misses.reported(.window(5), pid: 1, receivedAt: request * 10 + 2, echo: true)
    }
    let tripped = misses.willRequest(pid: 1, at: 200)
    #expect(!tripped)
    #expect(misses.inARow == 0)
}

@Test func echoesArrivingAfterTheNextRequestKeepTheCountDown() {
    // Holding a focus key across windows of one app: each request's activation read names the
    // window key before it, and its echo lands after the next request.
    var misses = FocusMisses<Int>()
    var tripped = false
    for request in 0..<20 {
        tripped = misses.willRequest(pid: 1, at: request * 10) || tripped
        if request > 0 { misses.reported(.window(UInt32(request)), pid: 1, receivedAt: request * 10 + 1, echo: true) }
        misses.reported(.window(9), pid: 1, receivedAt: request * 10 + 2, echo: false)
    }
    #expect(!tripped)
}

@Test func anotherAppsReportIsNotAMiss() {
    var misses = FocusMisses<Int>()
    for request in 0..<10 {
        _ = misses.willRequest(pid: 1, at: request * 10)
        misses.reported(.window(9), pid: 2, receivedAt: request * 10 + 1, echo: false)
    }
    #expect(misses.inARow == 0)
}

@Test func aReportReceivedBeforeTheRequestIsNotItsReadBack() {
    var misses = FocusMisses<Int>()
    for request in 1...10 {
        _ = misses.willRequest(pid: 1, at: request * 10)
        misses.reported(.window(9), pid: 1, receivedAt: request * 10 - 1, echo: false)
    }
    #expect(misses.inARow == 0)
}

@Test func aDroppedRequestIsNotJudged() {
    var misses = FocusMisses<Int>()
    for request in 0..<10 {
        _ = misses.willRequest(pid: 1, at: request * 10)
        misses.requestDropped(at: request * 10)
        misses.reported(.window(9), pid: 1, receivedAt: request * 10 + 1, echo: false)
    }
    #expect(misses.inARow == 0)
}

@Test func silenceAndNoKeyWindowAreNotMisses() {
    var misses = FocusMisses<Int>()
    for request in 0..<10 {
        _ = misses.willRequest(pid: 1, at: request * 10)
        if request.isMultiple(of: 2) { misses.reported(.none, pid: 1, receivedAt: request * 10 + 1, echo: false) }
    }
    #expect(misses.inARow == 0)
}
