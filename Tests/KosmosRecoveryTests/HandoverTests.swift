import Testing
@testable import KosmosRecovery

private let t0 = ContinuousClock.now

private func armed(_ arguments: [String] = [], at instant: ContinuousClock.Instant = t0) -> Handover {
    var handover = Handover()
    #expect(handover.arm(arguments, hiding: true, at: instant) == nil)
    return handover
}

@Test func anArmHandsOverTheQuitWithinItsLife() {
    let handover = armed()
    #expect(handover.handsOver(at: t0 + .milliseconds(7), guardianReady: true))
    #expect(!handover.handsOver(at: t0 + Handover.life, guardianReady: true))
    #expect(!Handover().handsOver(at: t0, guardianReady: true))
}

/// No other process would restore the windows should no Kosmos follow (`handover-unready`).
@Test func anArmedQuitHandsNothingOverWithoutAReadyGuardian() {
    #expect(!armed().handsOver(at: t0, guardianReady: false))
}

@Test func theVersionGivenMustBeTheOneThisBuildWrites() {
    #expect(armed([String(RecoveryRecord.version)]).handsOver(at: t0, guardianReady: true))
    var handover = Handover()
    let refusal = handover.arm([String(RecoveryRecord.version + 1)], hiding: true, at: t0)
    #expect(refusal?.hasPrefix("the next Kosmos reads record version \(RecoveryRecord.version + 1)") == true)
    #expect(!handover.handsOver(at: t0, guardianReady: true))
}

/// So the install quits the Kosmos it could not arm with recovery (docs/hiding.md).
@Test func aRefusalClearsAnEarlierArm() {
    for (arguments, hiding) in [(["1", "2"], true), (["one"], true), ([String(RecoveryRecord.version + 1)], true), ([], false)] {
        var handover = armed()
        #expect(handover.arm(arguments, hiding: hiding, at: t0 + .milliseconds(1)) != nil)
        #expect(!handover.handsOver(at: t0 + .milliseconds(2), guardianReady: true))
    }
}

@Test func aSecondArmStartsTheLifeAgain() {
    var handover = armed()
    #expect(handover.arm([], hiding: true, at: t0 + .seconds(4)) == nil)
    #expect(handover.handsOver(at: t0 + .seconds(8), guardianReady: true))
}

@Test func beforeKosmosManagesWindowsNothingArms() {
    var handover = Handover()
    #expect(handover.arm([], hiding: false, at: t0) == "no windows are hidden before Kosmos manages them")
    #expect(handover.arm(["1", "2"], hiding: true, at: t0) == "usage: handover [record version]")
}

@Test func aTimelyQuitKeepsItsHandoverWhileWorkersFinish() {
    var handover = armed()
    let began = handover.beginQuit(at: t0 + .milliseconds(7))
    #expect(began)
    #expect(handover.handsOver(at: t0 + .seconds(8), guardianReady: true))
    #expect(!handover.handsOver(at: t0 + .seconds(8), guardianReady: false))
}

@Test func aLateQuitDoesNotReviveAnExpiredHandover() {
    var handover = armed()
    let began = handover.beginQuit(at: t0 + Handover.life)
    #expect(began)
    #expect(!handover.handsOver(at: t0 + .seconds(8), guardianReady: true))
}

@Test func repeatedQuitRequestsKeepTheFirstRequestTime() {
    var handover = armed()
    let began = handover.beginQuit(at: t0 + .milliseconds(7))
    #expect(began)
    let repeated = handover.beginQuit(at: t0 + .seconds(8))
    #expect(!repeated)
    #expect(handover.handsOver(at: t0 + .seconds(9), guardianReady: true))
}
