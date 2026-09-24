import Testing
@testable import KosmosCore

// Every order in which the worker's job and the queue's 30 ms wait can meet. Stamps: the
// worker reads at 2, the queue decides at 3.

@Test func theWorkerRecordsAndRaisesThenTheQueueKeys() {
    var request = KeyRequest<Int>()
    let reads = request.workerStarts(isCurrent: true)
    let step = request.workerRead(alreadyKey: false, now: 2)
    let decision = request.queueDecides(now: 3)
    #expect(reads && step == .record(2))
    #expect(decision?.stamp == 2 && decision?.recordsItself == false)
}

@Test func aStaleRequestIsSkippedBeforeTheQueueDecides() {
    var request = KeyRequest<Int>()
    let reads = request.workerStarts(isCurrent: false)
    let decision = request.queueDecides(now: 3)
    #expect(!reads && decision == nil)
}

@Test func aTargetAlreadyKeyIsSkippedBeforeTheQueueDecides() {
    var request = KeyRequest<Int>()
    _ = request.workerStarts(isCurrent: true)
    let step = request.workerRead(alreadyKey: true, now: 2)
    let decision = request.queueDecides(now: 3)
    #expect(step == .stop && decision == nil)
}

@Test func onceTheQueueRecordsALateStaleJobStillRaises() {
    // The review's case: focus left then right while the app's worker drains frames. The
    // queue records and keys; the record alone keys nothing in the front app, so the late
    // job must raise.
    var request = KeyRequest<Int>()
    let decision = request.queueDecides(now: 3)
    let reads = request.workerStarts(isCurrent: false)
    let step = request.workerRead(alreadyKey: false, now: 4)
    #expect(decision?.stamp == 3 && decision?.recordsItself == true)
    #expect(reads && step == .raise)
}

@Test func onceTheQueueRecordsALateAlreadyKeyAnswerForgetsTheRecord() {
    var request = KeyRequest<Int>()
    _ = request.queueDecides(now: 3)
    _ = request.workerStarts(isCurrent: true)
    let step = request.workerRead(alreadyKey: true, now: 4)
    #expect(step == .drop(3))
}

@Test func theQueueDecidesWhileTheWorkerReads() {
    var raising = KeyRequest<Int>()
    _ = raising.workerStarts(isCurrent: true)
    let recordsItself = raising.queueDecides(now: 3)?.recordsItself
    #expect(recordsItself == true && raising.workerRead(alreadyKey: false, now: 4) == .raise)

    var dropping = KeyRequest<Int>()
    _ = dropping.workerStarts(isCurrent: true)
    _ = dropping.queueDecides(now: 3)
    #expect(dropping.workerRead(alreadyKey: true, now: 4) == .drop(3))
}

@Test func withNoWorkerJobTheQueueRecords() {
    var request = KeyRequest<Int>()
    let decision = request.queueDecides(now: 3)
    #expect(decision?.stamp == 3 && decision?.recordsItself == true)
}
