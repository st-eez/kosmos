import Testing
@testable import KosmosCore

// Each test replays the key window reports behind a design change in tla/README.md or a live
// case in docs/focus.md and docs/focus-follows-mouse.md, through the intake as the Controller
// drives it. Replay stands in for the Controller: where the windows are, the requests the
// focus queue records, and the reports and misses the Controller shares with them.

private let kosmos: Int32 = 1
private let ghostty: Int32 = 100
private let preview: Int32 = 200
private let helium: Int32 = 300
private let finder: Int32 = 400
private let chrome: Int32 = 500
private let activityMonitor: Int32 = 600
private let moonlight: Int32 = 700
private let claude: Int32 = 800

private func ms(_ milliseconds: Int) -> ContinuousClock.Instant { t0 + .milliseconds(milliseconds) }

private let commandTab = ActivationInput(key: 0.2, leftClick: 3600, rightClick: 3600, moved: 4)
/// In a window.
private let click = ActivationInput(key: 30, leftClick: 0.3, rightClick: 3600, moved: 0.05)

private final class Log {
    var notes: [KeyReportIntake.Note] = []
    /// Reads of whether a window left the screen, which can wait on WindowServer.
    var departureReads = 0

    var missed: [KeyWindow] {
        notes.compactMap { note -> KeyWindow? in if case .missed(let key, _) = note { key } else { nil } }
    }
}

private struct Replay {
    var intake = KeyReportIntake(ownApp: kosmos)
    var reports = FocusReports()
    var misses = FocusMisses()
    /// Each placed window's workspace and app.
    var windows: [WindowID: (workspace: String, app: Int32)]
    var shown: Set<String> = ["1"]
    var parked: Set<WindowID> = []
    var closedByApp: Set<WindowID> = []
    /// Concealed now. `conceals` has the changes whose stamps a report is judged against.
    var concealed: Set<WindowID> = []
    var conceals = ConcealHistory()
    var left: Set<WindowID> = []
    var intent: KeyWindow = .noWindow
    var locked = false
    var mouseFollowsFocus = true
    var leftButtonDown = false
    /// Command-Tab or a Dock click picked the window.
    var pickedAway = false
    var pressedJustBefore = false
    var launchedSinceEmptyWorkspaceKeyed: Set<Int32> = []
    let log = Log()

    var facts: KeyReportIntake.Facts {
        let windows = windows, shown = shown, parked = parked, closedByApp = closedByApp, concealed = concealed
        let conceals = conceals, left = left, log = log, leftButtonDown = leftButtonDown, pickedAway = pickedAway
        let pressedJustBefore = pressedJustBefore, launched = launchedSinceEmptyWorkspaceKeyed
        return KeyReportIntake.Facts(
            workspace: { windows[$0]?.workspace }, isShown: { shown.contains($0) }, isParked: { parked.contains($0) },
            closedByApp: { closedByApp.contains($0) },
            wasConcealed: { conceals.wasConcealed($0, at: $1, now: concealed.contains($0)) },
            leftScreen: { log.departureReads += 1; return left.contains($0) }, app: { windows[$0]?.app },
            intent: intent, locked: locked, recovered: false, mouseFollowsFocus: mouseFollowsFocus,
            pointer: PointerReadings(focusOnAnotherDisplay: { false }, leftButtonDown: { leftButtonDown },
                                     activation: { (pickedAway ? commandTab : click, onDock: false) }),
            userPressedJustBefore: { pressedJustBefore }, launchedSinceEmptyWorkspaceKeyed: { launched.contains($0) },
            note: { log.notes.append($0) })
    }

    mutating func heard(_ key: KeyWindow, from app: Int32, at milliseconds: Int) -> KeyReportIntake.Action {
        intake.heard(key, from: app, receivedAt: ms(milliseconds), facts: facts, reports: &reports, misses: &misses)
    }

    mutating func expire(_ number: Int) -> KeyReportIntake.Action {
        intake.expire(number, facts: facts, reports: &reports)
    }

    mutating func admit(_ window: WindowID, atLaunch: Bool = false, at milliseconds: Int)
        -> (focus: AdmissionFocus, bringsPointer: Bool) {
        let facts = facts
        return intake.admit(window, atLaunch: atLaunch, at: ms(milliseconds), facts: facts, reports: reports)
    }

    mutating func placed(_ window: WindowID) -> KeyReportIntake.Action {
        intake.placed(window, facts: facts, reports: &reports, misses: &misses)
    }

    mutating func tabReplaced(_ old: WindowID, with new: WindowID, concealing: Bool) -> KeyReportIntake.Action {
        intake.tabReplaced(old, with: new, concealing: concealing)
        return placed(new)
    }

    /// As the focus queue records a request just before its call. A key record also goes to
    /// the kill switch's count, and `retry` follows a miss.
    mutating func requested(_ key: KeyWindow, app: Int32, at milliseconds: Int, keyRecord: Bool = false, retry: Bool = false) {
        reports.focusRequested(key, app: app, at: ms(milliseconds))
        if keyRecord, case .window(let window) = key {
            _ = misses.willRequest(window, pid: app, at: ms(milliseconds), retry: retry)
        }
    }

    /// A hotkey, a socket command or a hover focus.
    mutating func command(at milliseconds: Int) {
        reports.commandExecuted(receivedAt: ms(milliseconds))
    }
}

// MARK: Live cases

@Test func hoverOntoABackgroundAppsSecondWindowAdoptsTheWindowItsAppReportedFirst() {
    // Live on 2026-09-24 at 23:56: with Activity Monitor front, the pointer entered Preview's
    // window 100924, and Preview reported 99816, 100924 and 99816 within about 40 ms. The
    // first is neither a repeat nor an echo, so it is adopted, with no miss logged; the rule
    // that an activation read matches its app's key record is deferred (docs/focus.md).
    var replay = Replay(windows: [50: ("1", activityMonitor), 99816: ("1", preview), 100924: ("1", preview)])
    #expect(replay.heard(.window(50), from: activityMonitor, at: -100) == .adopt(50, bringsPointer: false))
    replay.command(at: 0)
    replay.requested(.window(100924), app: preview, at: 2, keyRecord: true)
    #expect(replay.heard(.window(99816), from: preview, at: 10) == .adopt(99816, bringsPointer: false))
    replay.requested(.window(99816), app: preview, at: 12)
    #expect(replay.heard(.window(100924), from: preview, at: 20) == .none)
    #expect(replay.heard(.window(99816), from: preview, at: 30) == .none)
    #expect(replay.log.missed.isEmpty)
    #expect(replay.log.departureReads == 0)
}

@Test func aHeldReportOfTheAppsLastKeyWindowIsDroppedOnceKosmossEchoMovesTheKeyOn() {
    // Live on 2026-09-25: from workspace 6, alt-1 key-recorded Ghostty's window on workspace 1.
    // Ghostty first keyed its last key window, concealed on workspace 5, then the requested
    // one, and the grace used to follow the first to workspace 5 (docs/focus.md).
    var replay = Replay(windows: [60: ("6", helium), 11: ("1", ghostty), 15: ("5", ghostty)], shown: ["1", "6"],
                        concealed: [15])
    _ = replay.heard(.window(60), from: helium, at: -100)
    replay.command(at: 0)
    replay.requested(.window(11), app: ghostty, at: 5, keyRecord: true)
    #expect(replay.heard(.window(15), from: ghostty, at: 10) == .hold(1))
    #expect(replay.heard(.window(11), from: ghostty, at: 20) == .none)
    #expect(replay.expire(1) == .none)
    let held = KeyReportIntake.Report(key: .window(15), received: ms(10), reporter: ghostty, previous: 60,
                                      concealed: true, miss: .none)
    #expect(replay.log.notes.last == .heldMovedOn(held, key: .window(11)))
}

@Test func aHeldReportIsDecidedByWhetherTheKeyWindowBeforeItLeft() {   // change 11
    // Live: Command-H on the only window of workspace 2 took Kosmos to workspace 1, where
    // macOS keyed Ghostty before WindowServer ordered the hidden app's window out.
    var replay = Replay(windows: [21: ("2", helium), 11: ("1", ghostty)], shown: ["2"], concealed: [11])
    _ = replay.heard(.window(21), from: helium, at: -100)
    #expect(replay.heard(.window(11), from: ghostty, at: 10) == .hold(1))
    replay.left = [21]
    #expect(replay.expire(1) == .requestFocus(retry: false))
    // A Command-Tab follows as usual, 100 ms late.
    replay.left = []
    replay.pickedAway = true
    #expect(replay.heard(.window(21), from: helium, at: 200) == .adopt(21, bringsPointer: true))
    #expect(replay.heard(.window(11), from: ghostty, at: 300) == .hold(2))
    #expect(replay.expire(2) == .follow(11, bringsPointer: true))
}

@Test func aReportOfAnotherWindowReplacesTheHeldOneAndARepeatLeavesItHeld() {
    var replay = Replay(windows: [21: ("2", helium), 22: ("2", preview), 11: ("1", ghostty)], shown: ["2"],
                        concealed: [11])
    _ = replay.heard(.window(21), from: helium, at: -100)
    #expect(replay.heard(.window(11), from: ghostty, at: 10) == .hold(1))
    // An activation read after its notification. The spec drops this check with the miss
    // rule (tla/README.md, change 21); Kosmos keeps both (docs/focus.md).
    #expect(replay.heard(.window(11), from: ghostty, at: 12) == .none)
    #expect(replay.heard(.window(22), from: preview, at: 20) == .adopt(22, bringsPointer: false))
    #expect(replay.expire(1) == .none)
    let held = KeyReportIntake.Report(key: .window(11), received: ms(10), reporter: ghostty, previous: 21,
                                      concealed: true, miss: .none)
    #expect(replay.log.notes.contains(.replaced(held: held, by: .window(22))))
}

@Test func aLateReportStampedBeforeTheHeldOneStillReplacesIt() {
    // The spec takes such a report as overtaken by the held one (tla/README.md, change 21);
    // Kosmos defers that rule (docs/focus.md, Deferred).
    var replay = Replay(windows: [21: ("2", helium), 22: ("2", preview), 11: ("1", ghostty)], shown: ["2"],
                        concealed: [11])
    _ = replay.heard(.window(21), from: helium, at: -100)
    #expect(replay.heard(.window(11), from: ghostty, at: 10) == .hold(1))
    #expect(replay.heard(.window(22), from: preview, at: 5) == .adopt(22, bringsPointer: false))
    #expect(replay.expire(1) == .none)
}

@Test func aHeldReportWhoseWindowParkedIsDropped() {
    var replay = Replay(windows: [21: ("2", helium), 11: ("1", ghostty)], shown: ["2"], concealed: [11])
    _ = replay.heard(.window(21), from: helium, at: -100)
    #expect(replay.heard(.window(11), from: ghostty, at: 10) == .hold(1))
    replay.parked = [11]
    #expect(replay.expire(1) == .none)
    let held = KeyReportIntake.Report(key: .window(11), received: ms(10), reporter: ghostty, previous: 21,
                                      concealed: true, miss: .none)
    #expect(replay.log.notes.last == .heldWindowLeft(held))
}

@Test func aNewWindowItsAppKeyedBeforeItsAdmissionTakesTheFocusAtAdmission() {
    // Live on 2026-09-25: Cmd-N in Ghostty on workspace 1 keyed the new window before Kosmos
    // admitted it (docs/focus-follows-mouse.md). The admission moves the pointer itself.
    var replay = Replay(windows: [11: ("1", ghostty)])
    _ = replay.heard(.window(11), from: ghostty, at: -100)
    #expect(replay.heard(.window(12), from: ghostty, at: 10) == .none)
    replay.windows[12] = ("1", ghostty)
    let admission = replay.admit(12, at: 20)
    #expect(admission.focus == .adopt && admission.bringsPointer)
    #expect(replay.placed(12) == .none)
    // A native tab dragged out of its group is admitted with the drag still on.
    #expect(replay.heard(.window(13), from: ghostty, at: 30) == .none)
    replay.windows[13] = ("1", ghostty)
    replay.leftButtonDown = true
    let dragged = replay.admit(13, at: 40)
    #expect(dragged.focus == .adopt && !dragged.bringsPointer)
    // At launch the key window takes the focus and leaves the pointer, and another takes
    // neither.
    replay.leftButtonDown = false
    #expect(replay.heard(.window(14), from: ghostty, at: 50) == .none)
    replay.windows[14] = ("1", ghostty)
    replay.windows[15] = ("1", ghostty)
    let key = replay.admit(14, atLaunch: true, at: 60)
    #expect(key.focus == .adopt && !key.bringsPointer)
    let other = replay.admit(15, atLaunch: true, at: 60)
    #expect(other.focus == .none && !other.bringsPointer)
}

@Test func aNewWindowItsAppKeysWithinASecondOfItsAdmissionBringsThePointer() {
    // A launch can key its first window after Kosmos admitted it on a shown workspace
    // (docs/focus-follows-mouse.md).
    var replay = Replay(windows: [11: ("1", ghostty), 12: ("1", ghostty), 13: ("1", ghostty), 14: ("1", ghostty)])
    _ = replay.heard(.window(11), from: ghostty, at: -100)
    #expect(replay.admit(12, at: 0).focus == .awaitKey)
    #expect(replay.admit(13, at: 0).focus == .awaitKey)
    #expect(replay.admit(14, at: 0).focus == .awaitKey)
    #expect(replay.heard(.window(12), from: ghostty, at: 999) == .adopt(12, bringsPointer: true))
    // A native tab dragged out of its group is admitted with the drag still on.
    replay.leftButtonDown = true
    #expect(replay.heard(.window(13), from: ghostty, at: 999) == .adopt(13, bringsPointer: false))
    // After the second the Command-Tab test decides.
    replay.leftButtonDown = false
    #expect(replay.heard(.window(14), from: ghostty, at: 1000) == .adopt(14, bringsPointer: false))
}

@Test func aReopenedWindowClosedAndKeptIsDecidedAtItsNewPlace() {
    // Its key report waits for the place it takes as a new window (docs/tree.md), here on
    // its rule's workspace, which no display shows.
    var replay = Replay(windows: [11: ("1", ghostty), 30: ("1", activityMonitor)], parked: [30], closedByApp: [30])
    _ = replay.heard(.window(11), from: ghostty, at: -100)
    #expect(replay.heard(.window(30), from: activityMonitor, at: 10) == .none)
    replay.parked = []
    replay.closedByApp = []
    replay.concealed = [30]
    replay.windows[30] = ("4", activityMonitor)
    #expect(replay.admit(30, at: 20).focus == .placedHidden)
    #expect(replay.placed(30) == .follow(30, bringsPointer: true))
}

@Test func onlyAReportThatWouldEndAHeldOneEndsTheWaitingReport() {
    // As for a held report, a report of no key window, Kosmos's echo or a parked window's
    // report leaves it (docs/focus.md).
    var replay = Replay(windows: [11: ("1", ghostty), 30: ("1", activityMonitor), 31: ("1", preview)],
                        parked: [30, 31], closedByApp: [30], intent: .window(11))
    _ = replay.heard(.window(11), from: ghostty, at: -100)
    #expect(replay.heard(.window(30), from: activityMonitor, at: 10) == .none)
    // 31 is minimized, and macOS keys it just before it returns.
    #expect(replay.heard(.window(31), from: preview, at: 20) == .none)
    #expect(replay.heard(.noWindow, from: finder, at: 22) == .none)
    replay.requested(.window(11), app: ghostty, at: 24)
    #expect(replay.heard(.window(11), from: ghostty, at: 26) == .none)
    replay.parked = [31]
    replay.closedByApp = []
    #expect(replay.admit(30, at: 30).focus == .adopt)
    // A report of another window ends it.
    #expect(replay.heard(.window(32), from: preview, at: 40) == .none)
    replay.windows[32] = ("1", preview)
    #expect(replay.heard(.window(11), from: ghostty, at: 50) == .adopt(11, bringsPointer: false))
    #expect(replay.admit(32, at: 60).focus == .awaitKey)
}

@Test func kosmossEchoAfterTheWaitingReportLeavesItToTheAdmission() {
    // Kosmos keyed Claude again before Chrome's first window, keyed at launch, was admitted
    // to workspace 4, which no display shows (docs/focus.md).
    var replay = Replay(windows: [80: ("8", claude)], shown: ["1", "8"])
    _ = replay.heard(.window(80), from: claude, at: -100)
    replay.requested(.window(80), app: claude, at: 5)
    #expect(replay.heard(.window(70), from: chrome, at: 10) == .none)
    #expect(replay.heard(.window(80), from: claude, at: 15) == .none)
    replay.windows[70] = ("4", chrome)
    #expect(replay.admit(70, at: 20).focus == .placedHidden)
    #expect(replay.placed(70) == .follow(70, bringsPointer: true))
    // On a shown workspace it takes the focus.
    replay.requested(.window(70), app: chrome, at: 25)
    #expect(replay.heard(.window(71), from: chrome, at: 30) == .none)
    #expect(replay.heard(.window(70), from: chrome, at: 35) == .none)
    replay.windows[71] = ("8", chrome)
    #expect(replay.admit(71, at: 40).focus == .adopt)
}

@Test func aCommandAfterTheWaitingReportWinsAtTheAdmission() {
    // As over a Command-Tab (docs/focus.md).
    var replay = Replay(windows: [11: ("1", ghostty)])
    _ = replay.heard(.window(11), from: ghostty, at: -100)
    #expect(replay.heard(.window(12), from: ghostty, at: 10) == .none)
    replay.command(at: 15)
    replay.windows[12] = ("1", ghostty)
    #expect(replay.admit(12, at: 20).focus == .awaitKey)
    #expect(replay.placed(12) == .none)
}

@Test func aParkedWindowsReportOnlyConsumesItsEcho() {
    // The pointer focuses a native fullscreen window it enters, and the window stays parked
    // (docs/focus-follows-mouse.md).
    var replay = Replay(windows: [11: ("1", ghostty), 40: ("1", moonlight)], parked: [40])
    _ = replay.heard(.window(11), from: ghostty, at: -100)
    replay.command(at: 0)
    replay.requested(.window(40), app: moonlight, at: 5, keyRecord: true)
    #expect(replay.heard(.window(40), from: moonlight, at: 10) == .none)
    #expect(!replay.reports.isEcho(.window(40), receivedAt: ms(11)))
    #expect(replay.heard(.window(40), from: moonlight, at: 20) == .none)
    #expect(replay.intake.key == .window(40))
    #expect(!replay.log.notes.contains(where: { note in if case .verdict(.window(40), _) = note { true } else { false } }))
}

@Test func aReportWhileLockedIsOnlyHeard() {
    // The resync after the unlock requests the intent again and forgets the echoes due
    // (docs/focus.md).
    var replay = Replay(windows: [11: ("1", ghostty), 12: ("1", ghostty), 13: ("1", ghostty)])
    _ = replay.heard(.window(11), from: ghostty, at: -100)
    let bound = replay.intake.awaitNextKey(after: 11)
    #expect(replay.admit(13, at: 0).focus == .awaitKey)
    replay.requested(.window(12), app: ghostty, at: 5)
    replay.locked = true
    #expect(replay.heard(.window(12), from: ghostty, at: 10) == .none)
    #expect(replay.intake.key == .window(12))
    #expect(replay.reports.isEcho(.window(12), receivedAt: ms(11)))
    let ended = replay.intake.boundEnds(bound)
    #expect(ended)
    replay.locked = false
    replay.reports.forgetRequests()
    #expect(replay.heard(.window(13), from: ghostty, at: 500) == .adopt(13, bringsPointer: true))
}

@Test func aHeldReportWhoseGraceEndsWhileLockedDecidesNothing() {
    // The session locked during the grace; the resync after the unlock requests the intent
    // again (docs/focus.md).
    var replay = Replay(windows: [21: ("2", helium), 11: ("1", ghostty)], shown: ["2"], concealed: [11])
    _ = replay.heard(.window(21), from: helium, at: -100)
    #expect(replay.heard(.window(11), from: ghostty, at: 10) == .hold(1))
    replay.locked = true
    #expect(replay.expire(1) == .none)
    let held = KeyReportIntake.Report(key: .window(11), received: ms(10), reporter: ghostty, previous: 21,
                                      concealed: true, miss: .none)
    #expect(replay.log.notes.last == .heldWhileLocked(held))
    #expect(replay.log.departureReads == 1)
}

@Test func aNewWindowOnARulesHiddenWorkspaceIsFollowedWithThePointer() {
    // Live on 2026-09-25: Chrome launched from workspace 8, and a rule put its first window
    // on workspace 4, which no display showed. Its worker reports its key window as it
    // starts, before the window is admitted (docs/focus.md).
    var replay = Replay(windows: [80: ("8", claude)], shown: ["1", "8"])
    _ = replay.heard(.window(80), from: claude, at: -100)
    #expect(replay.heard(.window(70), from: chrome, at: 10) == .none)
    replay.windows[70] = ("4", chrome)
    #expect(replay.admit(70, at: 20).focus == .placedHidden)
    #expect(replay.placed(70) == .follow(70, bringsPointer: true))
    #expect(replay.log.departureReads == 0)
    // A command received after the report wins, as over a Command-Tab.
    #expect(replay.heard(.window(71), from: chrome, at: 30) == .none)
    replay.command(at: 40)
    replay.windows[71] = ("4", chrome)
    #expect(replay.admit(71, at: 50).focus == .placedHidden)
    #expect(replay.placed(71) == .requestFocus(retry: false))
}

@Test func aReportBeforeTheAdmissionsConcealLandsIsFollowedAndOneAfterLosesToTheIntent() {
    var replay = Replay(windows: [80: ("8", claude), 70: ("4", chrome), 71: ("4", chrome)], shown: ["1", "8"])
    _ = replay.heard(.window(80), from: claude, at: -100)
    #expect(replay.admit(70, at: 0).focus == .placedHidden)
    #expect(replay.placed(70) == .none)
    #expect(replay.heard(.window(70), from: chrome, at: 10) == .follow(70, bringsPointer: true))
    // Once the conceal has landed Kosmos requests its intent again, and the echo that comes
    // after the report moves the key on.
    #expect(replay.admit(71, at: 20).focus == .placedHidden)
    replay.intake.forgetPlacedHidden([71])
    replay.concealed = [71]
    replay.requested(.window(80), app: claude, at: 25)
    #expect(replay.heard(.window(71), from: chrome, at: 30) == .hold(1))
    #expect(replay.heard(.window(80), from: claude, at: 40) == .none)
    #expect(replay.expire(1) == .none)
}

@Test func aTabKeyedBeforeItsPlaceIsDecidedWhenItTakesTheDeselectedTabsPlace() {
    // Its key window before it, the deselected tab, did not depart (docs/tree.md).
    var replay = Replay(windows: [11: ("1", ghostty), 20: ("3", ghostty)])
    _ = replay.heard(.window(11), from: ghostty, at: -100)
    #expect(replay.heard(.window(12), from: ghostty, at: 10) == .none)
    replay.windows[12] = ("1", ghostty)
    replay.windows[11] = nil
    #expect(replay.tabReplaced(11, with: 12, concealing: false) == .adopt(12, bringsPointer: false))
    #expect(replay.log.departureReads == 0)
    // A switch the replace conceals takes the key window with it, and until its conceal
    // lands a report of the new tab is followed.
    replay.windows[21] = ("3", ghostty)
    replay.windows[12] = nil
    #expect(replay.tabReplaced(12, with: 21, concealing: true) == .none)
    #expect(replay.intake.key == .window(21))
    #expect(replay.heard(.window(21), from: ghostty, at: 20) == .follow(21, bringsPointer: false))
}

@Test func withMouseFollowsFocusOffNoReportBringsThePointer() {
    var replay = Replay(windows: [11: ("1", ghostty), 12: ("1", ghostty), 13: ("1", ghostty), 15: ("5", ghostty)],
                        concealed: [15])
    replay.mouseFollowsFocus = false
    replay.pickedAway = true
    _ = replay.heard(.window(11), from: ghostty, at: -100)
    #expect(replay.heard(.window(12), from: ghostty, at: 10) == .adopt(12, bringsPointer: false))
    #expect(replay.heard(.window(15), from: ghostty, at: 20) == .hold(1))
    #expect(replay.expire(1) == .follow(15, bringsPointer: false))
    #expect(replay.admit(13, at: 30).focus == .awaitKey)
    #expect(replay.heard(.window(13), from: ghostty, at: 40) == .adopt(13, bringsPointer: false))
    #expect(replay.heard(.window(14), from: ghostty, at: 50) == .none)
    replay.windows[14] = ("1", ghostty)
    let admission = replay.admit(14, at: 60)
    #expect(admission.focus == .adopt && !admission.bringsPointer)
}

@Test func anAppFrontedWithNoKeyWindowOnAnEmptyWorkspaceIsKeyedAwayUnlessTheUserChoseIt() {
    // Live on 2026-09-24: a click on the desktop of the left panel, which showed an empty
    // workspace, fronted Finder, and Cmd-Q quit it (docs/focus.md).
    var replay = Replay(windows: [:], shown: ["7"])
    replay.requested(.noWindow, app: kosmos, at: 0)
    #expect(replay.heard(.noWindow, from: kosmos, at: 5) == .none)
    replay.pressedJustBefore = true
    #expect(replay.heard(.noWindow, from: finder, at: 10) == .none)
    replay.pressedJustBefore = false
    replay.launchedSinceEmptyWorkspaceKeyed = [finder]
    #expect(replay.heard(.noWindow, from: finder, at: 20) == .none)
    replay.launchedSinceEmptyWorkspaceKeyed = []
    #expect(replay.heard(.noWindow, from: finder, at: 30) == .keyEmptyWorkspaceAgain(app: finder))
    #expect(replay.heard(.noWindow, from: kosmos, at: 40) == .none)
    replay.intent = .window(11)
    #expect(replay.heard(.noWindow, from: finder, at: 50) == .none)
}

// MARK: Design changes

@Test func macOSsReportOfTheNextKeyWindowEndsADeparturesWaitAndKosmossEchoDoesNot() {   // change 13
    // A window keyed during a minimize's animation leaves macOS nothing to key when it ends.
    var replay = Replay(windows: [11: ("1", ghostty), 12: ("1", ghostty), 13: ("1", helium)])
    _ = replay.heard(.window(11), from: ghostty, at: -100)
    let first = replay.intake.awaitNextKey(after: 11)
    replay.requested(.window(12), app: ghostty, at: 5)
    #expect(replay.heard(.window(12), from: ghostty, at: 10) == .none)
    let firstEnded = replay.intake.boundEnds(first)
    #expect(firstEnded)
    _ = replay.heard(.window(11), from: ghostty, at: 100)
    let second = replay.intake.awaitNextKey(after: 11)
    replay.left = [11]
    #expect(replay.heard(.window(13), from: helium, at: 110) == .adopt(13, bringsPointer: false))
    let secondEnded = replay.intake.boundEnds(second)
    #expect(!secondEnded)
}

@Test func macOSsReKeyOntoAHiddenWindowAfterTheKeyWindowLeftKeepsTheWorkspace() {   // changes 8 and 24
    // The key window minimized and macOS keyed a concealed window of another app. The
    // activation read after the notification repeats its window, and finds the same window
    // key before it.
    var replay = Replay(windows: [11: ("1", ghostty), 31: ("3", preview)], concealed: [31], left: [11])
    _ = replay.heard(.window(11), from: ghostty, at: -100)
    #expect(replay.heard(.window(31), from: preview, at: 10) == .requestFocus(retry: false))
    #expect(replay.heard(.window(31), from: preview, at: 12) == .requestFocus(retry: false))
}

@Test func aMissIsRequestedAgainOnceThenTheKeyWindowStays() {   // change 12
    // Live: Kosmos fronted Ghostty for a window of workspace 1, and Ghostty reported the
    // window a switch had just concealed on workspace 3 again.
    var replay = Replay(windows: [11: ("1", ghostty), 13: ("3", ghostty)], concealed: [13])
    replay.conceals.changed([13], concealed: true, at: ms(2))
    _ = replay.heard(.window(13), from: ghostty, at: -100)
    replay.command(at: 0)
    replay.requested(.window(11), app: ghostty, at: 5, keyRecord: true)
    #expect(replay.heard(.window(13), from: ghostty, at: 10) == .requestFocus(retry: true))
    replay.requested(.window(11), app: ghostty, at: 12, keyRecord: true, retry: true)
    #expect(replay.heard(.window(13), from: ghostty, at: 15) == .none)
    #expect(replay.log.missed == [.window(13), .window(13)])
}

@Test func aBackgroundReportLeavesTheKeyWindowSoACommandTabIsFollowed() {   // change 17
    // A busy app's late raise of window 3, after the user switched away, changed only that
    // background app's focused window. The Controller hands such a report to FocusReports
    // alone.
    var replay = Replay(windows: [1: ("1", ghostty), 2: ("1", helium), 3: ("3", ghostty)], concealed: [3])
    _ = replay.heard(.window(2), from: helium, at: -100)
    replay.requested(.window(3), app: ghostty, at: 0)
    let echo = replay.reports.consumeEcho(.window(3), receivedAt: ms(20))
    #expect(echo)
    #expect(replay.intake.key == .window(2))
    replay.pickedAway = true
    #expect(replay.heard(.window(3), from: ghostty, at: 30) == .hold(1))
    #expect(replay.expire(1) == .follow(3, bringsPointer: true))
}

@Test func whetherAWindowWasHiddenIsJudgedAtTheReportsStamp() {   // change 19
    // alt-3 at 5 ms. The user clicks window 1 at 10 ms, before the switch conceals it at
    // 12 ms, and the report is decided after the conceal: the switch wins. A Command-Tab to
    // window 2 after the conceal is followed.
    var replay = Replay(windows: [1: ("1", ghostty), 2: ("1", helium), 3: ("3", preview)], shown: ["3"],
                        concealed: [1, 2])
    replay.conceals.changed([1, 2], concealed: true, at: ms(12))
    _ = replay.heard(.window(2), from: helium, at: -100)
    replay.command(at: 5)
    #expect(replay.heard(.window(1), from: ghostty, at: 10) == .requestFocus(retry: false))
    #expect(replay.log.departureReads == 0)
    #expect(replay.heard(.window(2), from: helium, at: 20) == .hold(1))
    #expect(replay.expire(1) == .follow(2, bringsPointer: false))
}

@Test func aHiddenWindowOpenedInsideTheFrontAppIsFollowed() {   // change 22
    // The Window menu or `open` on a document keys a concealed window of the front app, and
    // only the app's notification reports it.
    var replay = Replay(windows: [11: ("1", ghostty), 15: ("5", ghostty)], concealed: [15])
    _ = replay.heard(.window(11), from: ghostty, at: -100)
    #expect(replay.heard(.window(15), from: ghostty, at: 10) == .hold(1))
    #expect(replay.expire(1) == .follow(15, bringsPointer: false))
    #expect(replay.log.departureReads == 2)
}

@Test func theRaiseAfterAKeyRecordHasAnEchoThatGoesOnceTheRaiseIsDone() {   // change 23
    var replay = Replay(windows: [1: ("1", ghostty), 2: ("1", helium)])
    _ = replay.heard(.window(2), from: helium, at: -100)
    replay.command(at: 0)
    replay.requested(.window(1), app: ghostty, at: 5, keyRecord: true)
    #expect(replay.heard(.window(1), from: ghostty, at: 10) == .none)
    // The raise after it, which the app reports again: an echo, and no miss.
    replay.requested(.window(1), app: ghostty, at: 12)
    #expect(replay.heard(.window(1), from: ghostty, at: 14) == .none)
    #expect(replay.log.missed.isEmpty)
    // A raise that changed nothing: the worker's word that it is done forgets its record,
    // so the user's later choice of the window is theirs.
    replay.requested(.window(1), app: ghostty, at: 20)
    replay.reports.requestDropped(.window(1), at: ms(20))
    #expect(replay.heard(.window(2), from: helium, at: 30) == .adopt(2, bringsPointer: false))
    #expect(replay.heard(.window(1), from: ghostty, at: 40) == .adopt(1, bringsPointer: false))
}
