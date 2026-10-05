import CoreGraphics
import Testing
@testable import KosmosCore

private let main = CGRect(x: 0, y: 0, width: 1920, height: 1080)
private let rightOfMain = CGRect(x: 1920, y: 0, width: 2560, height: 1440)
private let leftOfMain = CGRect(x: -1512, y: 0, width: 1512, height: 982)
private let size = CGSize(width: 945, height: 1035)
private let rest = CGRect(x: 965, y: 35, width: 945, height: 1035)
private let edge = CGRect(x: 1919, y: 40, width: 945, height: 1035)

@Test func aPeekTakesTheRightEdgeWithItsTop40PointsDown() {
    let found = PeekEdge.frame(size, on: main, besides: [])
    #expect(found?.edge == .right)
    #expect(found?.frame == edge)
    #expect(found.map { $0.frame.intersection(main).width } == 1)
}

@Test func aPeekTakesTheLeftEdgeWhenAnotherDisplayLiesPastTheRight() {
    let found = PeekEdge.frame(size, on: main, besides: [rightOfMain])
    #expect(found?.edge == .left)
    #expect(found?.frame == CGRect(x: -944, y: 40, width: 945, height: 1035))
    #expect(PeekEdge.frame(size, on: main, besides: [rightOfMain, leftOfMain]) == nil)
}

@Test func aDisplayAboveOrBelowLeavesBothEdgesFree() {
    let above = CGRect(x: 0, y: -1440, width: 2560, height: 1440)
    #expect(PeekEdge.frame(size, on: main, besides: [above])?.edge == .right)
}

@Test func aWindowTallerThanItsDisplayKeepsItsTopOnTheDisplay() {
    #expect(PeekEdge.frame(CGSize(width: 800, height: 1200), on: main, besides: [])?.frame.minY == 0)
    #expect(PeekEdge.frame(CGSize(width: 800, height: 1060), on: main, besides: [])?.frame.minY == 20)
}

private func ready(_ window: WindowID) -> Peeks.Preparation { .ready(rest: rest, edge: edge) }

/// The peek's action when there is exactly one of that kind.
private func only(_ actions: [Peeks.Action]) -> Peeks.Action? { actions.count == 1 ? actions[0] : nil }

/// A peek of window 7 taken through its steps to the command's run.
private func running() -> (Peeks, Int) {
    var peeks = Peeks()
    let number = peeks.request(7)
    _ = peeks.next(prepare: ready)
    _ = peeks.landed(number, frame: edge)
    _ = peeks.revealed(number, true)
    _ = peeks.settled(number)
    #expect(peeks.active?.phase == .running)
    return (peeks, number)
}

@Test func aPeekMovesRevealsSettlesRunsThenConcealsAndMovesBack() {
    var peeks = Peeks()
    let number = peeks.request(7)
    #expect(peeks.active == nil)
    guard case .move(let peek)? = only(peeks.next(prepare: ready)) else { Issue.record("no move"); return }
    #expect(peek.window == 7 && peek.rest == rest && peek.edge == edge && peek.phase == .moving)
    #expect(peeks.next(prepare: ready).isEmpty)
    // A row from before the write is no landing, nor is a read back at the edge.
    #expect(peeks.landed(number, frame: rest).isEmpty)
    #expect(peeks.answered(number, readBack: edge).isEmpty)
    guard case .reveal(let out)? = only(peeks.landed(number, frame: edge.offsetBy(dx: 0.5, dy: 0))) else {
        Issue.record("no reveal"); return
    }
    #expect(out.phase == .revealing)
    guard case .settle? = only(peeks.revealed(number, true)) else { Issue.record("no settle"); return }
    guard case .run(let run)? = only(peeks.settled(number)) else { Issue.record("no run"); return }
    #expect(run.phase == .running)
    #expect(peeks.ended(number, .finished) == [.end(run, .finished, conceal: true, rest: rest)])
    #expect(peeks.isEmpty)
    // The CLI's close after the end changes nothing.
    #expect(peeks.ended(number, .clientGone).isEmpty)
}

@Test func aSecondPeekWaitsForTheFirstAndStartsOnlyWhenNextIsCalled() {
    var (peeks, first) = running()
    let second = peeks.request(8)
    #expect(peeks.next(prepare: ready).isEmpty)
    #expect(peeks.active?.number == first)
    #expect(only(peeks.ended(first, .finished)) != nil)
    #expect(peeks.windows == [8])
    guard case .move(let next)? = only(peeks.next(prepare: ready)) else { Issue.record("the second did not start"); return }
    #expect(next.number == second && next.window == 8)
}

@Test func aPeekWaitsWhileAWriteToItsWindowLands() {
    var peeks = Peeks()
    let number = peeks.request(7)
    let until = ContinuousClock.now + .milliseconds(900)
    #expect(peeks.next { _ in .later(until: until) } == [.retry(at: until)])
    #expect(peeks.active == nil && peeks.windows == [7])
    guard case .move(let peek)? = only(peeks.next(prepare: ready)) else { Issue.record("no move"); return }
    #expect(peek.number == number)
}

@Test func aWaitingPeekWhoseWindowIsNoLongerConcealedEndsWithoutTouchingIt() {
    var (peeks, first) = running()
    let second = peeks.request(8)
    let third = peeks.request(9)
    _ = peeks.ended(first, .finished)
    let actions = peeks.next { $0 == 8 ? .none(.notConcealed) : ready($0) }
    #expect(actions.count == 2)
    guard case .end(let skipped, .notConcealed, false, nil) = actions[0] else { Issue.record("8 not left as is"); return }
    #expect(skipped.number == second)
    guard case .move(let next) = actions[1] else { Issue.record("9 did not start"); return }
    #expect(next.number == third)
}

@Test func aRefusedEdgeEndsThePeekWithTheWindowStillConcealed() {
    var peeks = Peeks()
    let number = peeks.request(7)
    _ = peeks.next(prepare: ready)
    let kept = CGRect(x: 975, y: 40, width: 945, height: 1035)
    guard case .end(let peek, .refused(kept), false, rest)? = only(peeks.answered(number, readBack: kept)) else {
        Issue.record("not refused"); return
    }
    #expect(peek.phase == .moving)

    var unseen = Peeks()
    let other = unseen.request(7)
    _ = unseen.next(prepare: ready)
    guard case .end(_, .refused(nil), false, rest)? = only(unseen.moveEnded(other)) else { Issue.record("not timed out"); return }
    // Too late once the window is out.
    var (out, late) = running()
    #expect(out.moveEnded(late).isEmpty)
}

@Test func aWindowThatDidNotLeaveTheHoldingSpaceIsPutBack() {
    var peeks = Peeks()
    let number = peeks.request(7)
    _ = peeks.next(prepare: ready)
    _ = peeks.landed(number, frame: edge)
    guard case .end(_, .notRevealed, true, rest)? = only(peeks.revealed(number, false)) else { Issue.record("not put back"); return }
}

@Test func theTimeoutEndsTheRunningPeek() {
    var (peeks, number) = running()
    guard case .end(_, .timedOut, true, rest)? = only(peeks.ended(number, .timedOut)) else { Issue.record("not timed out"); return }
    #expect(peeks.isEmpty)
}

@Test(arguments: [Peeks.Outcome.shown, .resynced, .locked, .screensSlept, .displaysChanged, .quit, .clientGone])
func eachPhaseEndsAsItCanBeUndone(outcome: Peeks.Outcome) {
    // Waiting: nothing to undo.
    var (peeks, first) = running()
    let second = peeks.request(8)
    guard case .end(let waiting, outcome, false, nil)? = only(peeks.giveWay(8, outcome)) else { Issue.record("waiting"); return }
    #expect(waiting.number == second)
    #expect(peeks.active?.number == first)

    // Moving: still concealed, so only the frame goes back.
    var moving = Peeks()
    _ = moving.request(7)
    _ = moving.next(prepare: ready)
    guard case .end(_, outcome, false, rest)? = only(moving.giveWay(7, outcome)) else { Issue.record("moving"); return }

    // Revealing, settling and running: back in the holding Space, then the frame.
    var revealing = Peeks()
    let number = revealing.request(7)
    _ = revealing.next(prepare: ready)
    _ = revealing.landed(number, frame: edge)
    guard case .end(_, outcome, true, rest)? = only(revealing.giveWay(nil, outcome)) else { Issue.record("revealing"); return }
    guard case .end(let out, outcome, true, rest)? = only(peeks.giveWay(nil, outcome)) else { Issue.record("running"); return }
    #expect(out.number == first)
    #expect(peeks.isEmpty)
}

@Test func aClosedWindowIsNeitherConcealedNorMoved() {
    var (peeks, number) = running()
    guard case .end(let peek, .closed, false, nil)? = only(peeks.giveWay(7, .closed)) else { Issue.record("not left alone"); return }
    #expect(peek.number == number)
}

@Test func givingWayForOneWindowLeavesTheOthers() {
    var (peeks, _) = running()
    let second = peeks.request(8)
    #expect(peeks.giveWay(9, .shown).isEmpty)
    #expect(peeks.giveWay(7, .shown).count == 1)
    guard case .move(let next)? = only(peeks.next(prepare: ready)) else { Issue.record("8 did not start"); return }
    #expect(next.number == second)
    // A lock ends every peek, and a later step of any changes nothing.
    let third = peeks.request(9)
    let locked = peeks.giveWay(nil, .locked)
    #expect(locked.count == 2)
    #expect(peeks.isEmpty)
    #expect(peeks.ended(third, .finished).isEmpty)
}

@Test func stepsForAnEndedPeekChangeNothing() {
    var peeks = Peeks()
    let number = peeks.request(7)
    _ = peeks.next(prepare: ready)
    _ = peeks.landed(number, frame: edge)
    _ = peeks.giveWay(7, .shown)
    // The reveal's answer comes after the end, which the bridge queue runs after it.
    #expect(peeks.revealed(number, true).isEmpty)
    #expect(peeks.settled(number).isEmpty)
    #expect(peeks.landed(number, frame: edge).isEmpty)
    #expect(peeks.moveEnded(number).isEmpty)
}
