/// Decides what each key window report does and whether the pointer comes (docs/focus.md;
/// tla/Kosmos.tla, Adopt and Hold). The Controller gathers the facts and runs the action.
public struct KeyReportIntake: Sendable {
    public struct Report: Equatable, Sendable {
        public let key: KeyWindow
        public let received: ContinuousClock.Instant
        public let reporter: Int32
        /// The key window before it, when that was another window.
        public let previous: WindowID?
        /// At the report's stamp.
        var concealed: Bool
        let miss: Miss
        /// Its app keyed it as Kosmos admitted it after launch, so following or adopting it
        /// brings the pointer (docs/focus-follows-mouse.md).
        var admitted = false
    }

    public enum Action: Equatable, Sendable {
        case none
        /// Request the focus intent again. `retry`: after a miss, which the kill switch counts
        /// once.
        case requestFocus(retry: Bool)
        case adopt(WindowID, bringsPointer: Bool)
        case follow(WindowID, bringsPointer: Bool)
        /// Call `expire` with the number when the grace ends.
        case hold(Int)
        /// The app is front with no key window on an empty workspace.
        case keyEmptyWorkspaceAgain(app: Int32)
    }

    /// What the log says of a report.
    public enum Note: Equatable, Sendable {
        case missed(KeyWindow, Miss)
        case verdict(KeyWindow, ReportVerdict)
        /// A report of a window ended the held one.
        case replaced(held: Report, by: KeyWindow)
        /// At the grace's end the held report's window had no place or was parked.
        case heldWindowLeft(Report)
        /// At the grace's end another window was key.
        case heldMovedOn(Report, key: KeyWindow?)
        /// At the grace's end, whether the key window before the held report left. `at`: the
        /// grace's end, before the read of whether it left.
        case heldDecided(Report, previous: WindowID, left: Bool, at: ContinuousClock.Instant)
    }

    /// What the Controller knows as it decides. The closures run only when a decision needs
    /// them.
    public struct Facts {
        public var workspace: (WindowID) -> String?
        public var isShown: (String) -> Bool
        public var isParked: (WindowID) -> Bool
        /// Parked as closed and kept by its app (docs/tree.md).
        public var closedByApp: (WindowID) -> Bool
        /// Whether Hiding held the window concealed at the stamp (docs/focus.md).
        public var wasConcealed: (WindowID, ContinuousClock.Instant) -> Bool
        /// Reads WindowServer, which can wait on a switch's Space transaction.
        public var leftScreen: (WindowID) -> Bool
        public var app: (WindowID) -> Int32?
        public var intent: KeyWindow
        public var locked: Bool
        /// After a failed batch, recovery showed the windows of hidden workspaces, so a click
        /// reaches them (docs/focus.md).
        public var recovered: Bool
        public var mouseFollowsFocus: Bool
        public var pointer: PointerReadings
        /// A key or mouse button went down within the last second.
        public var userPressedJustBefore: () -> Bool
        /// The app launched after the empty workspace's window last became key.
        public var launchedSinceEmptyWorkspaceKeyed: (Int32) -> Bool
        public var note: (Note) -> Void

        public init(workspace: @escaping (WindowID) -> String?, isShown: @escaping (String) -> Bool,
                    isParked: @escaping (WindowID) -> Bool, closedByApp: @escaping (WindowID) -> Bool,
                    wasConcealed: @escaping (WindowID, ContinuousClock.Instant) -> Bool,
                    leftScreen: @escaping (WindowID) -> Bool, app: @escaping (WindowID) -> Int32?,
                    intent: KeyWindow, locked: Bool, recovered: Bool, mouseFollowsFocus: Bool,
                    pointer: PointerReadings,
                    userPressedJustBefore: @escaping () -> Bool,
                    launchedSinceEmptyWorkspaceKeyed: @escaping (Int32) -> Bool,
                    note: @escaping (Note) -> Void) {
            self.workspace = workspace
            self.isShown = isShown
            self.isParked = isParked
            self.closedByApp = closedByApp
            self.wasConcealed = wasConcealed
            self.leftScreen = leftScreen
            self.app = app
            self.intent = intent
            self.locked = locked
            self.recovered = recovered
            self.mouseFollowsFocus = mouseFollowsFocus
            self.pointer = pointer
            self.userPressedJustBefore = userPressedJustBefore
            self.launchedSinceEmptyWorkspaceKeyed = launchedSinceEmptyWorkspaceKeyed
            self.note = note
        }
    }

    /// How long a report waits to learn whether the key window before it left: WindowServer
    /// ordered a hidden app's window out 17 ms after the hide (docs/tree.md). Every follow
    /// of a Command-Tab waits this long.
    public static let grace: Duration = .milliseconds(100)

    private static let keyAfterAdmission: Duration = .seconds(ActivationInput.maxAge)

    private let ownApp: Int32
    private var keyHistory = KeyHistory()
    /// The last key report of a window with no place, or parked as closed and kept, decided
    /// when the window takes a place (docs/focus.md).
    private var unplaced: Report?
    /// Admitted on a shown workspace before their apps keyed them (AdmissionFocus.awaitKey).
    /// A report within `keyAfterAdmission` brings the pointer (docs/focus-follows-mouse.md).
    private var admittedUnkeyed: [WindowID: ContinuousClock.Instant] = [:]
    /// Windows admitted to a hidden workspace, and tabs a switch placed on one, until their
    /// conceal lands. macOS keyed such a window by the user's or the app's choice, so its
    /// report is followed (docs/focus.md).
    private var placedHidden: [WindowID: Placed] = [:]
    private enum Placed { case admitted, tab }
    private var held = HeldReport<Report>()
    /// A departure waiting for macOS's report of the next key window (DepartureFocus).
    private var awaitingKey: (window: WindowID, number: Int)?
    private var departureNumber = 0

    /// `ownApp`: Kosmos's process, whose report of no key window is its empty workspace's.
    public init(ownApp: Int32) {
        self.ownApp = ownApp
    }

    /// The key window Kosmos last heard of. Too old to skip a focus request against; the focus
    /// queue checks as the request runs.
    public var key: KeyWindow? { keyHistory.key }

    /// A report of the front app's key window.
    public mutating func heard(_ reported: KeyWindow, from reporter: Int32, receivedAt stamp: ContinuousClock.Instant,
                               facts: Facts, reports: inout FocusReports, misses: inout FocusMisses) -> Action {
        let id: WindowID? = if case .window(let window) = reported { window } else { nil }
        let repeated = key == reported
        let previous: WindowID? = if case .window(let window)? = keyHistory.heard(reported), window != id { window } else { nil }
        guard !facts.locked else { return .none }   // resync requests the intent again
        admittedUnkeyed = admittedUnkeyed.filter { stamp - $0.value < Self.keyAfterAdmission }
        let keyedAfterAdmission = id.flatMap { admittedUnkeyed.removeValue(forKey: $0) } != nil
        // The report a departure waited for, unless it is Kosmos's echo: a window keyed
        // during a minimize's animation leaves macOS nothing to key when it ends.
        if let previous, awaitingKey?.window == previous, !reports.isEcho(reported, receivedAt: stamp) {
            awaitingKey = nil
        }
        let miss = reports.miss(reported, app: id.flatMap(facts.app), repeated: repeated, receivedAt: stamp)
        if miss != .none { facts.note(.missed(reported, miss)) }
        // An unmanaged window's focus is its own, and a parked one is key in its fullscreen
        // Space or just before it returns. A window with no place, or closed and kept, is
        // decided when it takes one.
        if let id, facts.workspace(id) == nil || facts.isParked(id) {
            unplaced = facts.workspace(id) == nil || facts.closedByApp(id)
                ? Report(key: reported, received: stamp, reporter: reporter, previous: previous, concealed: false, miss: miss)
                : nil
            // Kosmos keyed a native fullscreen window, as for hover focus: this is its echo.
            if facts.isParked(id), reports.consumeEcho(reported, receivedAt: stamp) {
                misses.reported(reported, pid: reporter, receivedAt: stamp, echo: true)
            }
            return .none
        }
        unplaced = nil
        if held.holds(reported, repeated: repeated) { return .none }
        // Whether the key window before this report just left the screen is read only when
        // the verdict needs it, as the read can wait on a switch's Space transaction.
        // Concealment is judged at the stamp (docs/focus.md; tla/README.md, change 22).
        let placed = id.flatMap { placedHidden.removeValue(forKey: $0) }
        let report = Report(key: reported, received: stamp, reporter: reporter, previous: previous,
                            concealed: placed != nil || id.map { facts.wasConcealed($0, stamp) } ?? false,
                            miss: miss, admitted: keyedAfterAdmission || placed == .admitted)
        return decidePlaced(report,
                            keyLeft: placed != nil ? .stayed : previous.map { facts.leftScreen($0) ? .left : .unknown } ?? .stayed,
                            facts: facts, reports: &reports, misses: &misses)
    }

    /// Admits `window`. The report its app keyed it by before it had a place waits for
    /// `placed` when Kosmos follows it to a hidden workspace, and is dropped otherwise.
    public mutating func admit(_ window: WindowID, atLaunch: Bool, at now: ContinuousClock.Instant,
                               facts: Facts) -> (focus: AdmissionFocus, bringsPointer: Bool) {
        let focus = AdmissionFocus.decide(keyed: key == .window(window),
                                          shown: facts.workspace(window).map(facts.isShown) == true,
                                          parked: facts.isParked(window), atLaunch: atLaunch, locked: facts.locked)
        switch focus {
        case .awaitKey: admittedUnkeyed[window] = now
        case .placedHidden: placedHidden[window] = .admitted
        case .adopt, .none: break
        }
        if unplaced?.key == .window(window) {
            if focus == .placedHidden {
                unplaced?.concealed = true
                unplaced?.admitted = true
            } else {
                unplaced = nil
            }
        }
        // A new window its app keyed brings the pointer on any display
        // (docs/focus-follows-mouse.md).
        return (focus, FocusChange.admission(focus, atLaunch: atLaunch)
            .movesPointer(mouseFollowsFocus: facts.mouseFollowsFocus, reading: facts.pointer))
    }

    /// `new` takes the deselected tab's place (docs/tree.md), before the replace's plan runs.
    /// `concealing`: the plan conceals it.
    public mutating func tabReplaced(_ old: WindowID, with new: WindowID, concealing: Bool) {
        placedHidden[old] = nil
        if concealing { placedHidden[new] = .tab }
        if key == .window(old) { keyHistory.key = .window(new) }
    }

    /// Decides the report `window`'s app keyed it by before it had a place, as one whose key
    /// window before it stayed (docs/focus.md).
    public mutating func placed(_ window: WindowID, facts: Facts, reports: inout FocusReports,
                                misses: inout FocusMisses) -> Action {
        guard var report = unplaced, report.key == .window(window), !facts.isParked(window) else { return .none }
        unplaced = nil
        placedHidden[window] = nil
        report.concealed = report.concealed || facts.workspace(window).map { !facts.isShown($0) } ?? false
        return decidePlaced(report, keyLeft: .stayed, facts: facts, reports: &reports, misses: &misses)
    }

    /// The grace of hold `number` ended. Every outcome is noted, to tell whether any report
    /// came before the first word of its departure.
    public mutating func expire(_ number: Int, facts: Facts, reports: inout FocusReports) -> Action {
        guard let report = held.expire(number) else { return .none }
        if case .window(let id) = report.key, facts.workspace(id) == nil || facts.isParked(id) {
            facts.note(.heldWindowLeft(report))
            return .none
        }
        // A later report moved the key window on, as Kosmos's own echo does when an app it
        // activated keys its last key window first and then the requested one.
        if report.key != key {
            facts.note(.heldMovedOn(report, key: key))
            return .none
        }
        guard let previous = report.previous else { return .none }
        let now = ContinuousClock.now
        let left = facts.leftScreen(previous)
        facts.note(.heldDecided(report, previous: previous, left: left, at: now))
        return decide(report, keyLeft: left ? .left : .stayed, facts: facts, reports: &reports)
    }

    /// Their workspace is shown, or the conceal that placed them hidden is done, or they closed.
    public mutating func forgetPlacedHidden(_ windows: [WindowID]) {
        for window in windows { placedHidden[window] = nil }
    }

    /// A departure waits for macOS's report of the key window after `window` (DepartureFocus).
    /// Returns the number of the wait's bound.
    public mutating func awaitNextKey(after window: WindowID) -> Int {
        departureNumber += 1
        awaitingKey = (window, departureNumber)
        return departureNumber
    }

    /// Whether bound `number` ends a wait no report ended, so the departure focuses.
    public mutating func boundEnds(_ number: Int) -> Bool {
        guard awaitingKey?.number == number else { return false }
        awaitingKey = nil
        return true
    }

    private mutating func decidePlaced(_ report: Report, keyLeft: @autoclosure () -> Departure, facts: Facts,
                                       reports: inout FocusReports, misses: inout FocusMisses) -> Action {
        let echo = reports.isEcho(report.key, receivedAt: report.received)
        misses.reported(report.key, pid: report.reporter, receivedAt: report.received, echo: echo)
        if !echo { reports.publicRequestsAnswered(by: report.reporter, receivedAt: report.received) }
        return decide(report, keyLeft: keyLeft(), facts: facts, reports: &reports)
    }

    /// A report whose verdict waits on a departure is held until it arrives or the grace ends
    /// (tla/Kosmos.tla, Adopt and Hold).
    private mutating func decide(_ report: Report, keyLeft: @autoclosure () -> Departure, facts: Facts,
                                 reports: inout FocusReports) -> Action {
        let id: WindowID? = if case .window(let window) = report.key { window } else { nil }
        let verdict = reports.classify(report.key, receivedAt: report.received,
                                       onShownWorkspace: id.flatMap(facts.workspace).map(facts.isShown) ?? false,
                                       concealed: report.concealed, recovered: facts.recovered, miss: report.miss,
                                       keyLeft: keyLeft())
        facts.note(.verdict(report.key, verdict))
        if id != nil, verdict != .echo, let ended = held.end() { facts.note(.replaced(held: ended, by: report.key)) }
        switch verdict {
        case .echo:
            return .none
        case .ignore:
            // macOS or an app fronted an app with no key window on an empty workspace: the
            // empty workspace keys its window again, so Cmd-Q reaches no app. After a click, a
            // Command-Tab or an app's launch it is the user's choice (docs/focus.md).
            guard report.key == .noWindow, report.reporter != ownApp, facts.intent == .noWindow,
                  !facts.userPressedJustBefore(), !facts.launchedSinceEmptyWorkspaceKeyed(report.reporter)
            else { return .none }
            return .keyEmptyWorkspaceAgain(app: report.reporter)
        case .undecided:
            return .hold(held.hold(report, of: report.key))
        case .reassert:
            return .requestFocus(retry: report.miss == .retry)
        case .adopt(let window):
            return .adopt(window, bringsPointer: bringsPointer(report, facts))
        case .follow(let window):
            return .follow(window, bringsPointer: bringsPointer(report, facts))
        }
    }

    /// Command-Tab, a launcher or a Dock click brings the pointer, on the window's own display
    /// too, and a click on the window leaves it (docs/focus-follows-mouse.md).
    private func bringsPointer(_ report: Report, _ facts: Facts) -> Bool {
        FocusChange.keyReport(admitted: report.admitted)
            .movesPointer(mouseFollowsFocus: facts.mouseFollowsFocus, reading: facts.pointer)
    }
}
