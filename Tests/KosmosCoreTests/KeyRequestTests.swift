import Testing
@testable import KosmosCore

// Every order in which the worker's job and the queue's 30 ms wait can meet. Stamps: the
// worker decides at 2 or 4, the queue decides at 3.

@Test func theWorkerRecordsAndRaisesThenTheQueueKeys() {
    var request = KeyRequest<Int>()
    let reads = request.workerStarts(isCurrent: true)
    let step = request.workerDecides(isCurrent: true, alreadyKey: false, appWasFront: true, now: 2)
    let decision = request.queueDecides(now: 3)
    #expect(reads && step == .record(2))
    #expect(decision?.stamp == 2 && decision?.recordsItself == false)
}

@Test func aStaleRequestIsSkippedBeforeTheRead() {
    var request = KeyRequest<Int>()
    let reads = request.workerStarts(isCurrent: false)
    let decision = request.queueDecides(now: 3)
    #expect(!reads && decision == nil)
}

@Test func aRequestStaleAfterASlowReadIsSkippedBeforeTheRaise() {
    var request = KeyRequest<Int>()
    _ = request.workerStarts(isCurrent: true)
    let step = request.workerDecides(isCurrent: false, alreadyKey: false, appWasFront: true, now: 2)
    let decision = request.queueDecides(now: 3)
    #expect(step == .stop && decision == nil)
}

@Test func aTargetAlreadyKeyIsSkippedBeforeTheQueueDecides() {
    var request = KeyRequest<Int>()
    _ = request.workerStarts(isCurrent: true)
    let step = request.workerDecides(isCurrent: true, alreadyKey: true, appWasFront: true, now: 2)
    let decision = request.queueDecides(now: 3)
    #expect(step == .stop && decision == nil)
}

@Test func onceTheQueueRecordsALateCurrentJobRaises() {
    // The queue recorded and keyed; in the front app the record alone keys nothing, so the
    // late job raises while the request is still the current one.
    var request = KeyRequest<Int>()
    let decision = request.queueDecides(now: 3)
    let reads = request.workerStarts(isCurrent: true)
    let step = request.workerDecides(isCurrent: true, alreadyKey: false, appWasFront: true, now: 4)
    #expect(decision?.stamp == 3 && decision?.recordsItself == true)
    #expect(reads && step == .raise)
}

@Test func onceTheQueueRecordsALateStaleJobInTheFrontAppForgetsTheRecord() {
    // Focus left then right while the front app's worker drains frames: the key record keyed
    // nothing, so no echo will come; a raise would report the window key against the newer
    // request.
    var request = KeyRequest<Int>()
    _ = request.queueDecides(now: 3)
    _ = request.workerStarts(isCurrent: false)
    let step = request.workerDecides(isCurrent: false, alreadyKey: false, appWasFront: true, now: 4)
    #expect(step == .drop(3))
}

@Test func onceTheQueueRecordsALateStaleJobInABackgroundAppDoesNothing() {
    // The review's cross-app race: the key record keyed the target and its echo clears the
    // record. A late raise could report the window key after a newer request keyed another
    // app's window, and Kosmos would adopt it.
    var request = KeyRequest<Int>()
    _ = request.queueDecides(now: 3)
    _ = request.workerStarts(isCurrent: false)
    let step = request.workerDecides(isCurrent: false, alreadyKey: false, appWasFront: false, now: 4)
    #expect(step == .stop)
}

@Test func onceTheQueueRecordsALateAlreadyKeyAnswerForgetsTheRecord() {
    var request = KeyRequest<Int>()
    _ = request.queueDecides(now: 3)
    _ = request.workerStarts(isCurrent: true)
    let step = request.workerDecides(isCurrent: true, alreadyKey: true, appWasFront: true, now: 4)
    #expect(step == .drop(3))
}

@Test func theQueueDecidesWhileTheWorkerReads() {
    var raising = KeyRequest<Int>()
    _ = raising.workerStarts(isCurrent: true)
    let recordsItself = raising.queueDecides(now: 3)?.recordsItself
    #expect(recordsItself == true)
    #expect(raising.workerDecides(isCurrent: true, alreadyKey: false, appWasFront: true, now: 4) == .raise)

    var dropping = KeyRequest<Int>()
    _ = dropping.workerStarts(isCurrent: true)
    _ = dropping.queueDecides(now: 3)
    #expect(dropping.workerDecides(isCurrent: true, alreadyKey: true, appWasFront: true, now: 4) == .drop(3))
}

@Test func withNoWorkerJobTheQueueRecords() {
    var request = KeyRequest<Int>()
    let decision = request.queueDecides(now: 3)
    #expect(decision?.stamp == 3 && decision?.recordsItself == true)
}
