import Testing
@testable import KosmosCore

// The split model's steps in tla/Kosmos.tla.

@Test func inTheFrontAppTheWorkerRaisesAndTheQueueKeysNothing() {
    let request = KeyRequest(appWasFront: true)
    #expect(request.workerStarts(isCurrent: true))
    #expect(request.workerRead(isCurrent: true, focused: .some(2), target: 1))
    #expect(request.workerRaises(isCurrent: true, appIsFront: true))
    #expect(!request.queueKeys(isCurrent: true, appIsFront: true))
}

@Test func aBackgroundAppIsKeyedByTheQueueAndNeverRaised() {
    // TLC's split-user-bgraise: a background app's raise keyed a stale window over a newer
    // activation.
    let request = KeyRequest(appWasFront: false)
    #expect(!request.workerStarts(isCurrent: true))
    #expect(request.queueKeys(isCurrent: true, appIsFront: false))
}

@Test func theQueueLeavesAnAppThatCameFrontOrAStaleRequest() {
    let request = KeyRequest(appWasFront: false)
    #expect(!request.queueKeys(isCurrent: true, appIsFront: true))
    #expect(!request.queueKeys(isCurrent: false, appIsFront: false))
}

@Test func aRequestForTheFrontAppIsNeverKeyedByTheQueueEvenAfterItLeftTheFront() {
    // The front app's request was the worker's to key, so a key record would be an
    // unrecorded change.
    #expect(!KeyRequest(appWasFront: true).queueKeys(isCurrent: true, appIsFront: false))
}

@Test func theWorkerRaisesNothingOnceItsAppLeftTheFront() {
    #expect(!KeyRequest(appWasFront: true).workerRaises(isCurrent: true, appIsFront: false))
}

@Test func aStaleRequestStopsAtEveryWorkerStep() {
    // TLC counterexamples 3 and 4: a stale request's record matched the user's own
    // Command-Tab or click on that window.
    let request = KeyRequest(appWasFront: true)
    #expect(!request.workerStarts(isCurrent: false))
    #expect(!request.workerRead(isCurrent: false, focused: .some(2), target: 1))
    #expect(!request.workerRaises(isCurrent: false, appIsFront: true))
}

@Test func afterTheKeyRecordTheWorkerRaisesOnlyTheFrontAppsFocusedTarget() {
    // TLC's split-user-nopostraise: without the raise the window stayed behind its app's
    // other windows.
    #expect(KeyRequest.workerPostRaises(appIsFront: true, focused: .some(1), target: 1))
    #expect(!KeyRequest.workerPostRaises(appIsFront: true, focused: .some(2), target: 1))
    #expect(!KeyRequest.workerPostRaises(appIsFront: false, focused: .some(1), target: 1))
    #expect(!KeyRequest.workerPostRaises(appIsFront: true, focused: nil, target: 1))
}
