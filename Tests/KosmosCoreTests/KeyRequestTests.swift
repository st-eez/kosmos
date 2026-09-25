import Testing
@testable import KosmosCore

// The split model's steps (tla/Kosmos.tla: WorkerStart, WorkerRead, WorkerRaise,
// FocusDecide).

@Test func inTheFrontAppTheWorkerRaisesAndTheQueueKeysNothing() {
    let request = KeyRequest(appWasFront: true)
    #expect(request.workerStarts(isCurrent: true))
    #expect(request.workerRead(isCurrent: true, focused: .some(2), target: 1))
    #expect(request.workerRaises(isCurrent: true, appIsFront: true))
    #expect(!request.queueKeys(isCurrent: true, appIsFront: true))
}

@Test func aBackgroundAppIsKeyedByTheQueueAndNeverRaised() {
    // split-user-bgraise: a raise in a background app landed after the app came front and
    // keyed a stale window over a newer activation.
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
    // The user switched away before the queue decided: the front app's request was the
    // worker's to key, and the queue's key record would be an unrecorded change.
    #expect(!KeyRequest(appWasFront: true).queueKeys(isCurrent: true, appIsFront: false))
}

@Test func theWorkerRaisesNothingOnceItsAppLeftTheFront() {
    #expect(!KeyRequest(appWasFront: true).workerRaises(isCurrent: true, appIsFront: false))
}

@Test func aStaleRequestStopsAtEveryWorkerStep() {
    // Counterexamples 3 and 4: a record taken by a stale request matched the user's own
    // Command-Tab or click on that window.
    let request = KeyRequest(appWasFront: true)
    #expect(!request.workerStarts(isCurrent: false))
    #expect(!request.workerRead(isCurrent: false, focused: .some(2), target: 1))
    #expect(!request.workerRaises(isCurrent: false, appIsFront: true))
}

@Test func aFrontAppsFocusedTargetIsKeyAlready() {
    #expect(!KeyRequest(appWasFront: true).workerRead(isCurrent: true, focused: .some(1), target: 1))
}

@Test func aFrontAppThatDoesNotAnswerTheReadStopsTheRequest() {
    // Going ahead left a record for a raise that changed nothing, which swallowed the user's
    // Command-Tab back to the window (kosmos-hover's TLC run).
    #expect(!KeyRequest(appWasFront: true).workerRead(isCurrent: true, focused: nil, target: 1))
}

@Test func afterTheKeyRecordTheWorkerRaisesOnlyTheFrontAppsFocusedTarget() {
    // split-user-nopostraise: without the raise the key record's window stayed behind its
    // app's other windows.
    #expect(KeyRequest.workerPostRaises(appIsFront: true, focused: .some(1), target: 1))
    // The user keyed another window of the app, or another app, since the key record.
    #expect(!KeyRequest.workerPostRaises(appIsFront: true, focused: .some(2), target: 1))
    #expect(!KeyRequest.workerPostRaises(appIsFront: false, focused: .some(1), target: 1))
    // The app did not answer the read.
    #expect(!KeyRequest.workerPostRaises(appIsFront: true, focused: nil, target: 1))
}
