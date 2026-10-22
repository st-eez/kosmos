import Testing
@testable import KosmosCore

@Test func aWindowThereBeforeTheClaimIsNotTheAgents() {
    let claim = AgentClaim(over: nil, before: [3210, 4687], at: t0)
    #expect(!claim.takes(4687, reopened: false))
    #expect(claim.takes(4700, reopened: false))
    #expect(claim.running(at: t0 + .milliseconds(9_999)) != nil)
    #expect(claim.running(at: t0 + .seconds(10)) == nil)
}

@Test func aWindowItsAppClosedAndKeptIsTakenWhenReopened() {
    let claim = AgentClaim(over: nil, before: [4687], at: t0)
    #expect(claim.takes(4687, reopened: true))
}

@Test func aClaimDuringAnotherKeepsWhatWasThereBeforeTheFirst() {
    var first = AgentClaim(over: nil, before: [3210], at: t0)
    first.windows.append((4700, t0 + .seconds(1)))
    let second = AgentClaim(over: first, before: [3210, 4700, 4701], at: t0 + .seconds(2))
    #expect(second.takes(4701, reopened: false))
    #expect(second.windows.map(\.id) == [4700])
    #expect(second.until == t0 + .seconds(12))
    let later = AgentClaim(over: first, before: [3210, 4701], at: t0 + .seconds(11))
    #expect(!later.takes(4701, reopened: false) && later.windows.isEmpty)
}
