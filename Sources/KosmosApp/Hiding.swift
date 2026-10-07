import CKosmos
import Foundation
import KosmosCore
import KosmosRecovery
import KosmosSkyLight
import Synchronization
import os

private let hidingLog = Logger(subsystem: "io.github.st-eez.kosmos", category: "hiding")

/// Conceals windows of hidden workspaces in one holding Space (docs/hiding.md). The record,
/// the Space and every recovery stay on the bridge queue, so a recovery never races a batch.
@MainActor
final class Hiding {
    struct Timing: Sendable {
        var queued = Duration.zero, sent = Duration.zero, confirmed = Duration.zero
        var recovered = Duration.zero, returned = Duration.zero
        /// Whether confirming took the barrier; nil when the batch read nothing.
        var barrier: Bool?
        var stripped = 0
    }

    enum Outcome: Sendable {
        /// With a bridged operation missing, nothing was concealed, and the status menu names
        /// it from launch.
        case confirmed
        /// No guardian was ready, so nothing was concealed.
        case revealedOnly
        /// Recovery ran, and the windows it could not restore stay concealed and recorded.
        case failed
    }

    private let guardian: Guardian
    private let missingOperation = SkyLight.missingBridgedOperation
    private let bridge = DispatchQueue(label: "kosmos.bridge", qos: .userInteractive)
    private let store: HidingStore
    /// A copy of the bridge queue's ledger as of its last job.
    private var concealed: Set<WindowID> = []
    /// The concealed windows under the desktop, as of the same job.
    private var underDesktop: Set<WindowID> = []
    private var batchesConcealing: [WindowID: Int] = [:]

    /// A description while concealed windows could not all be restored, nil once they are.
    var onProblem: (@MainActor (String?) -> Void)?

    init(record: RecordFile, guardian: Guardian) {
        self.guardian = guardian
        store = HidingStore(record: record)
        guardian.onUnavailable = { [weak self] in self?.restoreAll() }
    }

    func isConcealed(_ window: WindowID) -> Bool { concealed.contains(window) }

    /// Concealed under the desktop, where macOS still draws it and captures it, so a peek
    /// would add nothing (docs/hiding.md).
    func isUnderDesktop(_ window: WindowID) -> Bool { underDesktop.contains(window) }

    func isConcealedOrConcealing(_ window: WindowID) -> Bool { concealed.contains(window) || batchesConcealing[window] != nil }

    /// Windows are concealed, and slide through the pool's Spaces, only while this macOS has
    /// every bridged operation and the guardian would recover them.
    var canConceal: Bool { missingOperation == nil && guardian.isReady }

    func createAnimationSpaces(_ count: Int, level: Int32, done: @escaping @MainActor ([SpaceID]) -> Void) {
        let store = self.store
        bridge.async {
            let spaces = store.createAnimationSpaces(count, level: level)
            onMain { done(spaces) }
        }
    }

    func wasConcealed(_ window: WindowID, at stamp: ContinuousClock.Instant) -> Bool {
        store.history.withLock { $0.wasConcealed(window, at: stamp, now: concealed.contains(window)) }
    }

    /// Forgets a closed window once its concealing Space no longer lists it, so the record
    /// does not fill with closed windows; one still listed stays recorded (docs/hiding.md).
    func forgetClosed(_ window: WindowID) {
        store.history.withLock { $0.forget(window) }
        let store = self.store
        bridge.async {
            store.forgetClosed(window)
            let (concealed, under) = (store.concealed, store.underDesktop)
            onMain { (self.concealed, self.underDesktop) = (concealed, under) }
        }
    }

    /// Reveals `show`, then conceals `hide`, then confirms both (docs/hiding.md). Windows in
    /// `stripping` lose their ordinary Space only if this batch conceals them. Those of `hide`
    /// in `below`, the agent workspace's, go under the desktop.
    func apply(show: [WindowID], on displays: [WindowID: CGDirectDisplayID], hide: [WindowID], stripping: Set<WindowID>,
               below: Set<WindowID> = [], done: @escaping @MainActor (Outcome, Timing) -> Void) {
        let revealedOnly = missingOperation == nil && !guardian.isReady
        let hide = canConceal ? hide : []
        for window in hide { batchesConcealing[window, default: 0] += 1 }
        let store = self.store
        let submitted = ContinuousClock.now
        bridge.async {
            let started = ContinuousClock.now
            let (confirmed, sent, barrier, stripped) = store.apply(show: show, on: displays, hide: hide, stripping: stripping,
                                                                   below: below)
            let applied = ContinuousClock.now
            let outcome = confirmed ? nil : store.recover(keepingAnimationSpaces: true)
            let (concealed, under) = (store.concealed, store.underDesktop)
            let finished = ContinuousClock.now
            var timing = Timing(queued: started - submitted, sent: (sent ?? applied) - started,
                                confirmed: applied - (sent ?? applied), recovered: finished - applied, barrier: barrier,
                                stripped: stripped)
            onMain {
                timing.returned = .now - finished
                (self.concealed, self.underDesktop) = (concealed, under)
                for window in hide {
                    self.batchesConcealing[window]! -= 1
                    if self.batchesConcealing[window] == 0 { self.batchesConcealing[window] = nil }
                }
                if let outcome { self.report(outcome) }
                done(!confirmed ? .failed : revealedOnly ? .revealedOnly : .confirmed, timing)
            }
        }
    }

    /// Takes a concealed window out of its holding Space for a peek, adding it first to an
    /// ordinary Space of `display` when it has none. It stays concealed in the ledger, and the
    /// batch that conceals or reveals it next puts it back or lets it go (docs/hiding.md).
    /// `done` gets whether it left.
    func peek(_ window: WindowID, on display: CGDirectDisplayID?, done: @escaping @MainActor (Bool) -> Void) {
        let store = self.store
        bridge.async {
            let out = store.peek(window, on: display)
            onMain { done(out) }
        }
    }

    /// Forgets windows that left the holding Space on their own, as a deselected native tab
    /// does; kept, a batch would fail to find them there (docs/tree.md).
    func forget(_ windows: [WindowID]) {
        let store = self.store
        bridge.async {
            store.forget(windows)
            let (concealed, under) = (store.concealed, store.underDesktop)
            onMain { (self.concealed, self.underDesktop) = (concealed, under) }
        }
    }

    func restoreAll() {
        let store = self.store
        bridge.async {
            let outcome = store.recover(keepingAnimationSpaces: true)
            let (concealed, under) = (store.concealed, store.underDesktop)
            onMain {
                (self.concealed, self.underDesktop) = (concealed, under)
                self.report(outcome)
            }
        }
    }

    private func report(_ outcome: Recovery.Outcome) {
        if case .incomplete(let remaining) = outcome {
            onProblem?("\(remaining) hidden windows could not be restored; quitting Kosmos tries again")
        } else {
            onProblem?(nil)
        }
    }

    func recoverNow() -> Recovery.Outcome {
        let store = self.store
        return bridge.sync { store.recover(keepingAnimationSpaces: false) }
    }

    /// Takes over the record the Kosmos before this one left, in place of startup recovery,
    /// before any window is admitted (docs/hiding.md).
    func adopt() -> (Recovery.Outcome, Adoption) {
        let store = self.store
        let (outcome, adoption, concealed, under) = bridge.sync {
            let (outcome, adoption) = store.adopt()
            return (outcome, adoption, store.concealed, store.underDesktop)
        }
        (self.concealed, self.underDesktop) = (concealed, under)
        report(outcome)
        return (outcome, adoption)
    }

    /// Lets the queued batches land and leaves the record to the Kosmos that starts next.
    func handOver() {
        bridge.sync {}
    }
}

/// Used only on the bridge queue.
private final class HidingStore: @unchecked Sendable {
    private let record: RecordFile
    private var state: RecoveryRecord?
    private var space: SpaceID = 0
    /// Under the desktop, for the agent workspace's windows; 0 until one is needed.
    private var below: SpaceID = 0
    private var ledger = ConcealLedger()
    /// Windows the ledger holds that a peek took out of their concealing Space, and whether
    /// each was stripped of its ordinary Space.
    private var peeked: [WindowID: Bool] = [:]
    private var loaded = false
    /// Read on the main actor too.
    let history = Mutex(ConcealHistory())

    init(record: RecordFile) { self.record = record }

    var concealed: Set<WindowID> { Set(ledger.entries.keys) }

    var underDesktop: Set<WindowID> { below == 0 ? [] : Set(ledger.entries.filter { $0.value == below }.keys) }

    /// False while a recorded Space cannot be read: nothing is concealed or revealed until
    /// its state is known.
    private func load() -> Bool {
        if loaded { return true }
        guard let windowServer = ProcessIdentity.windowServer() else { return false }
        guard let onFile = record.read(), onFile.windowServer == windowServer else {
            state = RecoveryRecord(windowServer: windowServer, manager: .current)
            space = 0
            below = 0
            ledger = ConcealLedger()
            loaded = true
            return true
        }
        let read = SpaceMembers.read(onFile.spaces, of: onFile)
        guard let rebuilt = ConcealLedger.rebuilt(members: read.members.mapValues { Optional($0) }) else { return false }
        state = onFile
        state!.manager = .current
        state!.spaces.removeAll { read.gone.contains($0) }
        space = onFile.reusableSpace(members: read.members) ?? 0
        below = onFile.reusableSpace(members: read.members, below: true) ?? 0
        ledger = rebuilt
        loaded = true
        return true
    }

    /// `sent` is nil when the batch stopped before sending, `barrier` nil when it read nothing.
    func apply(show: [WindowID], on displays: [WindowID: CGDirectDisplayID], hide: [WindowID],
               stripping: Set<WindowID>, below agents: Set<WindowID>)
        -> (confirmed: Bool, sent: ContinuousClock.Instant?, barrier: Bool?, stripped: Int) {
        guard case (var batch, let sent)? = send(show: show, on: displays, hide: hide, stripping: stripping, below: agents)
        else { return (false, nil, nil, 0) }
        let touched = batch.touched
        guard let any = touched.first else { return (true, sent, nil, batch.strip.count) }
        func members() -> [SpaceID: Set<WindowID>] { Self.members(of: touched) }
        let confirmed = Self.readUntilDone(batch)
        if !confirmed {
            // A window that closed or was ordered out after its row read leaves the batch; a
            // failed row query leaves every window in, so recovery runs (docs/hiding.md).
            guard kosmos_barrier(any), let (kept, left) = batch.confirmed(members: members(), orderedIn: { failed in
                SkyLight.rows(Array(failed)).map { Set($0.filter(\.orderedIn).map(\.id)) } ?? failed
            }) else { return (false, sent, true, batch.strip.count) }
            if !left.isEmpty {
                // Their conceal never landed.
                history.withLock { history in left.intersection(batch.fresh).forEach { history.forget($0) } }
                hidingLog.notice("left out of the batch, closed or ordered out since their rows were read: \(left.sorted(), privacy: .public)")
            }
            batch = kept
        }
        ledger.commit(batch)
        return (true, sent, !confirmed, batch.strip.count)
    }

    private static let directReadsBeforeBarrier: Duration = .milliseconds(10)

    /// A Space whose read fails is left out, which proves nothing.
    private static func members(of spaces: Set<SpaceID>) -> [SpaceID: Set<WindowID>] {
        var members: [SpaceID: Set<WindowID>] = [:]
        for space in spaces {
            if let list = SkyLight.windows(in: space) { members[space] = Set(list) }
        }
        return members
    }

    /// Direct reads show the operations once WindowServer applied them; the barrier also waits
    /// behind WindowManager.app, so it goes only once the direct reads run out of time
    /// (docs/hiding.md).
    private static func readUntilDone(_ batch: ConcealLedger.Batch) -> Bool {
        let deadline = ContinuousClock.now + directReadsBeforeBarrier
        var done = batch.isDone(members: members(of: batch.touched))
        while !done && ContinuousClock.now < deadline {
            usleep(100)
            done = batch.isDone(members: members(of: batch.touched))
        }
        return done
    }

    /// As a reveal takes the window out, but the ledger keeps it (docs/hiding.md). False when
    /// it did not leave; the peek's end puts it back either way.
    func peek(_ window: WindowID, on display: CGDirectDisplayID?) -> Bool {
        guard load(), let held = ledger.entries[window] else { return false }
        var batch = ledger.batch(show: [window], hide: [], into: space, isOnAnySpace: Self.isOnAnySpace)
        peeked[window] = !batch.adds.isEmpty
        if !batch.adds.isEmpty {
            let displays = Displays.current()
            let original = state!.windows.first { $0.id == window }?.originalSpace
            guard let destination = displays.ordinarySpace(on: display, original: original) else { return false }
            Self.add([window], to: destination, exclusively: true)
            guard kosmos_barrier(held) else { return false }
            batch.removals = batch.removals(landed: displays.isInOrdinarySpace)
        }
        guard batch.removals[held]?.contains(window) == true else { return false }
        var ids = [window]
        kosmos_remove_windows(held, &ids, 1)
        return Self.readUntilDone(batch) || (kosmos_barrier(held) && batch.isDone(members: Self.members(of: [held])))
    }

    private func send(show: [WindowID], on showDisplays: [WindowID: CGDirectDisplayID], hide: [WindowID],
                      stripping: Set<WindowID>, below agents: Set<WindowID>) -> (ConcealLedger.Batch, ContinuousClock.Instant)? {
        guard load() else { return nil }
        let read = SkyLight.rows(hide)
        let rows = Dictionary((read ?? []).map { ($0.id, $0) }) { first, _ in first }
        let recorded = Set(state!.windows.map(\.id))
        var owners: [WindowID: ProcessIdentity] = [:]
        for (id, row) in rows where !recorded.contains(id) { owners[id] = ProcessIdentity.of(row.pid) }
        let hide = ConcealLedger.concealing(hide, rows: read == nil ? nil : Set(rows.keys), recorded: recorded, owned: Set(owners.keys))
        let fresh = Set(hide).filter { ledger.entries[$0] == nil }
        let wantsBelow = below == 0 && hide.contains(where: agents.contains)
        // A window leaving the Space under the desktop for a hidden workspace of the user's
        // needs the holding Space.
        let wantsHolding = space == 0 && hide.contains { !agents.contains($0) && ledger.entries[$0] != nil }
        if !fresh.isEmpty || wantsBelow || wantsHolding, !prepare(Array(fresh), owners: owners, below: wantsBelow) { return nil }
        let batch = ledger.batch(show: show, hide: hide, stripping: stripping, into: space, below: agents, under: below,
                                 isOnAnySpace: Self.isOnAnySpace)
        // Adds land before any removal: a window removed from its only Space lands on the
        // active Space, maybe a fullscreen one. Only a batch that adds pays the barrier and
        // the display read (docs/hiding.md).
        var removals = batch.removals
        if !batch.adds.isEmpty {
            let displays = Displays.current()
            let original = Dictionary(state!.windows.map { ($0.id, $0.originalSpace) }, uniquingKeysWith: { a, _ in a })
            var destinations: [SpaceID: [WindowID]] = [:]
            for window in batch.adds {
                guard let destination = displays.ordinarySpace(on: showDisplays[window], original: original[window]) else { return nil }
                destinations[destination, default: []].append(window)
            }
            for (destination, windows) in destinations { Self.add(windows, to: destination, exclusively: true) }
            guard let held = batch.removals.keys.first, kosmos_barrier(held) else { return nil }
            removals = batch.removals(landed: displays.isInOrdinarySpace)
        }
        // A window that changes concealing Space joins its new one before it leaves the old, so
        // it is never on screen; the exclusive add under the desktop strips its ordinary Space.
        for window in batch.moves {
            Self.add([window], to: batch.mustBeIn[window]!, exclusively: batch.mustBeIn[window] == below)
        }
        let moved = Set(batch.moves)
        history.withLock { $0.changed(removals.values.joined().filter { !moved.contains($0) }, concealed: false, at: .now) }
        for (from, windows) in removals {
            var ids = windows
            kosmos_remove_windows(from, &ids, ids.count)
        }
        history.withLock { $0.changed(batch.fresh, concealed: true, at: .now) }
        for (into, windows) in Dictionary(grouping: batch.fresh, by: { batch.mustBeIn[$0]! }) {
            Self.add(windows.filter { !batch.strip.contains($0) }, to: into, exclusively: false)
            Self.add(windows.filter(batch.strip.contains), to: into, exclusively: true)
        }
        // A peeked window this batch conceals goes back to its Space, stripped again if the peek
        // gave it an ordinary one; one it reveals is out already.
        for window in show where peeked[window] != nil { peeked[window] = nil }
        for (window, held) in batch.mustBeIn {
            guard let stripped = peeked.removeValue(forKey: window) else { continue }
            Self.add([window], to: held, exclusively: stripped)
        }
        return (batch, .now)
    }

    /// An exclusive add takes the windows out of their other managed Spaces.
    private static func add(_ windows: [WindowID], to space: SpaceID, exclusively: Bool) {
        kosmos_add_windows(space, windows, windows.count, exclusively)
    }

    func forgetClosed(_ window: WindowID) {
        guard load() else { return }
        forget(ledger.departed([window], members: SkyLight.windows(in:),
                               settled: { SkyLight.rows([$0]).map(\.isEmpty) ?? false || SkyLight.spaces(of: $0)?.isEmpty == false }))
    }

    func forget(_ windows: [WindowID]) {
        guard load() else { return }
        ledger.forget(windows)
        for window in windows { peeked[window] = nil }
        history.withLock { history in windows.forEach { history.forget($0) } }
        guard var next = state, next.windows.contains(where: { windows.contains($0.id) }) else { return }
        next.windows.removeAll { windows.contains($0.id) }
        if record.publish(next) { state = next }
    }

    /// Records the holding Space, and with `wantsBelow` the Space under the desktop, before
    /// any window enters it, and each window before its first hide.
    private func prepare(_ windows: [WindowID], owners: [WindowID: ProcessIdentity], below wantsBelow: Bool) -> Bool {
        var next = state!
        var created: [SpaceID] = []
        var holding: SpaceID = 0, under: SpaceID = 0
        if space == 0 {
            holding = kosmos_holding_create()
            guard holding != 0 else {
                hidingLog.error("holding Space not created")
                return false
            }
            created.append(holding)
            next.spaces.append(holding)
        }
        if wantsBelow {
            under = Self.createBelow()
            if under == 0 {
                hidingLog.error("no Space under the desktop; the agent workspace's windows go to the holding Space")
            } else {
                created.append(under)
                // First, where a Kosmos that predates the agent workspace never reuses it.
                next.spaces.insert(under, at: 0)
                next.belowSpaces.append(under)
            }
        }
        let known = Set(next.windows.map(\.id))
        let new = windows.filter { !known.contains($0) }
        for id in new {
            guard let owner = owners[id] else { return abandon(created) }
            let original = SkyLight.spaces(of: id)?.first ?? 0
            next.windows.append(.init(id: id, owner: owner, originalSpace: original))
        }
        if !record.publish(next) {
            // The record's slot is full: drop the windows that no longer exist.
            guard let rows = SkyLight.rows(next.windows.map(\.id)) else {
                hidingLog.error("the recorded windows could not be read; not concealing")
                return abandon(created)
            }
            let pruned = next.pruned(alive: Set(rows.map(\.id)), keeping: Set(ledger.entries.keys).union(windows))
            guard record.publish(pruned) else {
                hidingLog.error("the recovery record is full; not concealing")
                return abandon(created)
            }
            next = pruned
        }
        state = next
        if holding != 0 { space = holding }
        if under != 0 { below = under }
        return true
    }

    /// Destroys the Spaces created for a change never published, which hold no window.
    private func abandon(_ created: [SpaceID]) -> Bool {
        created.forEach { kosmos_space_destroy($0) }
        return false
    }

    /// One level under the desktop Space of the main display's ordinary Space, at alpha 1: the
    /// desktop picture covers its windows on every display, and macOS draws and captures them,
    /// as `kosmos-probe dwell` held two apps' windows there for 5 minutes (docs/hiding.md).
    /// 0 when the level does not read or the Space is not made.
    private static func createBelow() -> SpaceID {
        var level: Int32 = 0
        guard let ordinary = Displays.current().ordinarySpace(original: nil), kosmos_space_level(ordinary, &level)
        else { return 0 }
        return kosmos_float_space_create(level - 1)
    }

    /// Records the Spaces windows slide in before any window enters them.
    func createAnimationSpaces(_ count: Int, level: Int32) -> [SpaceID] {
        guard load() else { return [] }
        let created = (0..<count).map { _ in kosmos_float_space_create(level) }.filter { $0 != 0 }
        if created.count < count { hidingLog.error("\(count - created.count) of \(count) animation Spaces not created") }
        var next = state!
        next.animationSpaces += created
        guard record.publish(next) else {
            hidingLog.error("the recovery record cannot take \(created.count) more animation Spaces")
            created.forEach { kosmos_space_destroy($0) }
            return []
        }
        state = next
        return created
    }

    @discardableResult
    func recover(keepingAnimationSpaces keeping: Bool,
                 sparing: ((_ members: [WindowID], _ recorded: Set<WindowID>) -> Set<WindowID>)? = nil) -> Recovery.Outcome {
        let outcome = Recovery.run(file: record, keepingAnimationSpaces: keeping, sparing: sparing)
        hidingLog.notice("recovery: \(String(describing: outcome), privacy: .public)")
        history.withLock { $0.forgetAll() }   // recovery's reveals are not in the history
        peeked = [:]   // out already, as recovery leaves them
        loaded = false
        if !load() {
            // Every batch fails at load() and recovers again, so this ledger decides nothing.
            ledger = ConcealLedger()
        }
        return outcome
    }

    /// The ledger comes back from the Spaces' members, as after an incomplete recovery. A failed
    /// row query keeps nothing concealed, as it could not tell a closed window.
    func adopt() -> (Recovery.Outcome, Adoption) {
        var adoption = Adoption()
        let outcome = recover(keepingAnimationSpaces: false) { members, recorded in
            guard let rows = SkyLight.rows(members) else {
                hidingLog.error("the concealed windows' rows could not be read; restoring every one")
                return []
            }
            adoption = Adoption(members: rows.map { .init(id: $0.id, parent: $0.parent, orderedIn: $0.orderedIn) }, recorded: recorded)
            return adoption.windows
        }
        return (outcome, adoption)
    }

    /// kosmos_window_spaces leaves out the holding Space. A fullscreen Space counts too: an add
    /// to an ordinary Space would take the window out of it.
    private static func isOnAnySpace(_ window: WindowID) -> Bool {
        SkyLight.spaces(of: window)?.isEmpty == false
    }
}
