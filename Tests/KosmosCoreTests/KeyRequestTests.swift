import Testing
@testable import KosmosCore

// The split model's steps (tla/Kosmos.tla: WorkerStart, WorkerRead, WorkerRaise,
// FocusDecide) in each order they can meet. The worker raises at 2, the queue decides at 3.

@Test func inTheFrontAppTheWorkerRecordsAndRaisesAndTheQueueKeysNothing() {
    var request = KeyRequest<Int>(appWasFront: true)
    let goesOn = request.workerStarts(isCurrent: true) && request.workerRead(isCurrent: true, focused: .some(nil), target: 1)
    let step = request.workerRaises(isCurrent: true, appIsFront: true, now: 2)
    let key = request.queueDecides(isCurrent: true, appIsFront: true, now: 3)
    #expect(goesOn && step == .recordAndRaise(2) && key == nil)
}

@Test func inTheFrontAppTheQueueKeysNothingEvenWhenTheWorkerIsLate() {
    // The key record does nothing inside the front app; only the late raise keys.
    var request = KeyRequest<Int>(appWasFront: true)
    let key = request.queueDecides(isCurrent: true, appIsFront: true, now: 3)
    let step = request.workerRaises(isCurrent: true, appIsFront: true, now: 4)
    #expect(key == nil && step == .recordAndRaise(4))
}

@Test func aFrontAppsFocusedTargetIsKeyAlready() {
    let request = KeyRequest<Int>(appWasFront: true)
    #expect(!request.workerRead(isCurrent: true, focused: .some(1), target: 1))
}

@Test func aBackgroundAppIsRaisedWithoutARecordAndKeyedByTheQueue() {
    var request = KeyRequest<Int>(appWasFront: false)
    // The read is not made, so its answer does not matter.
    let goesOn = request.workerStarts(isCurrent: true) && request.workerRead(isCurrent: true, focused: .some(1), target: 1)
    let step = request.workerRaises(isCurrent: true, appIsFront: false, now: 2)
    let key = request.queueDecides(isCurrent: true, appIsFront: false, now: 3)
    #expect(goesOn && step == .raise && key == 3)
}

@Test func onceTheQueueHasKeyedTheLateWorkerRaisesNothing() {
    // Counterexample 5: a raise recorded after the queue keyed the window changed nothing,
    // and its record swallowed a later Command-Tab.
    var request = KeyRequest<Int>(appWasFront: false)
    let key = request.queueDecides(isCurrent: true, appIsFront: false, now: 3)
    let step = request.workerRaises(isCurrent: true, appIsFront: true, now: 4)
    #expect(key == 3 && step == .stop)
}

@Test func theQueueLeavesARequestTheWorkerIsKeying() {
    // The app came front before the worker's raise: the worker records and keys it.
    var request = KeyRequest<Int>(appWasFront: false)
    let step = request.workerRaises(isCurrent: true, appIsFront: true, now: 2)
    let key = request.queueDecides(isCurrent: true, appIsFront: true, now: 3)
    #expect(step == .recordAndRaise(2) && key == nil)
}

@Test func theQueueLeavesAnAppThatCameFrontOrAStaleRequest() {
    var cameFront = KeyRequest<Int>(appWasFront: false)
    #expect(cameFront.queueDecides(isCurrent: true, appIsFront: true, now: 3) == nil)
    var stale = KeyRequest<Int>(appWasFront: false)
    #expect(stale.queueDecides(isCurrent: false, appIsFront: false, now: 3) == nil)
}

@Test func aStaleRequestRecordsNothingAtAnyStep() {
    // Counterexamples 3 and 4: a record taken by a stale request matched the user's own
    // Command-Tab or click on that window.
    var request = KeyRequest<Int>(appWasFront: true)
    #expect(!request.workerStarts(isCurrent: false))
    #expect(!request.workerRead(isCurrent: false, focused: .some(nil), target: 1))
    #expect(request.workerRaises(isCurrent: false, appIsFront: true, now: 2) == .stop)
    #expect(request.phase == .pending)
}

@Test func aRequestForTheFrontAppIsNeverKeyedByTheQueueEvenAfterItLeftTheFront() {
    // The user switched away before the queue decided: the front app's request was the
    // worker's to key, and the queue's key record would be an unrecorded change.
    var request = KeyRequest<Int>(appWasFront: true)
    #expect(request.queueDecides(isCurrent: true, appIsFront: false, now: 3) == nil)
}

@Test func theQueueLeavesARequestTheWorkerKeyedEvenAfterTheAppLeftTheFront() {
    var request = KeyRequest<Int>(appWasFront: false)
    let step = request.workerRaises(isCurrent: true, appIsFront: true, now: 2)
    let key = request.queueDecides(isCurrent: true, appIsFront: false, now: 3)
    #expect(step == .recordAndRaise(2) && key == nil)
}

@Test func aFrontAppThatDoesNotAnswerTheReadStopsTheRequest() {
    // Going ahead left a record for a raise that changed nothing, which swallowed the user's
    // Command-Tab back to the window (kosmos-hover's TLC run).
    let request = KeyRequest<Int>(appWasFront: true)
    #expect(!request.workerRead(isCurrent: true, focused: nil, target: 1))
    // A background app is not read, and goes on.
    #expect(KeyRequest<Int>(appWasFront: false).workerRead(isCurrent: true, focused: nil, target: 1))
}
