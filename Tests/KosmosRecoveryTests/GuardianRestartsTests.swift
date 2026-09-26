import Testing
@testable import KosmosRecovery

private let t0 = ContinuousClock.now

@Test func theFourthFailureIn10SGivesUp() {
    var restarts = GuardianRestarts()
    let first = restarts.failed(at: t0), second = restarts.failed(at: t0 + .seconds(1))
    let third = restarts.failed(at: t0 + .seconds(2)), fourth = restarts.failed(at: t0 + .seconds(9))
    #expect(first && second && third && !fourth)
}

@Test func aFailure10SAfterTheFirstOfThreeRespawns() {
    var restarts = GuardianRestarts()
    let first = restarts.failed(at: t0), second = restarts.failed(at: t0 + .seconds(1))
    let third = restarts.failed(at: t0 + .seconds(2)), fourth = restarts.failed(at: t0 + .seconds(10))
    #expect(first && second && third && fourth)
}

@Test func failuresNoMoreThanThreeIn10SNeverGiveUp() {
    var restarts = GuardianRestarts()
    for index in 0..<8 {
        let respawns = restarts.failed(at: t0 + .seconds(Double(index) * 3.5))
        #expect(respawns)
    }
}
