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
        case confirmed
        /// No guardian was ready, or this macOS lacks a bridged operation, so nothing was
        /// concealed.
        case revealedOnly
        /// Recovery ran, and the windows it could not restore stay concealed and recorded.
        case failed
    }

    private let guardian: Guardian
    private let canHide = SkyLight.missingBridgedOperation == nil
    private let bridge = DispatchQueue(label: "kosmos.bridge", qos: .userInteractive)
    private let store: HidingStore
    /// A copy of the bridge queue's ledger as of its last job.
    private var concealed: Set<UInt32> = []
    private var batchesConcealing: [UInt32: Int] = [:]

    /// A description while concealed windows could not all be restored, nil once they are.
    var onProblem: (@MainActor (String?) -> Void)?

    init(record: RecordFile, guardian: Guardian) {
        self.guardian = guardian
        store = HidingStore(record: record)
        guardian.onUnavailable = { [weak self] in self?.restoreAll() }
    }

    func isConcealed(_ window: UInt32) -> Bool { concealed.contains(window) }

    func isConcealedOrConcealing(_ window: UInt32) -> Bool { concealed.contains(window) || batchesConcealing[window] != nil }

    /// Windows are concealed, and slide through the pool's Spaces, only while this macOS has
    /// every bridged operation and the guardian would recover them.
    var canConceal: Bool { canHide && guardian.isReady }

    func createAnimationSpaces(_ count: Int, level: Int32, done: @escaping @MainActor ([UInt64]) -> Void) {
        let store = self.store
        bridge.async {
            let spaces = store.createAnimationSpaces(count, level: level)
            onMain { done(spaces) }
        }
    }

    func wasConcealed(_ window: UInt32, at stamp: ContinuousClock.Instant) -> Bool {
        store.history.withLock { $0.wasConcealed(window, at: stamp, now: concealed.contains(window)) }
    }

    /// Forgets a closed window once its concealing Space no longer lists it, so the record
    /// does not fill with closed windows; one still listed stays recorded (docs/hiding.md).
    func forgetClosed(_ window: UInt32) {
        store.history.withLock { $0.forget(window) }
        let store = self.store
        bridge.async {
            store.forgetClosed(window)
            let concealed = store.concealed
            onMain { self.concealed = concealed }
        }
    }

    /// Reveals `show`, then conceals `hide`, then confirms both (docs/hiding.md). Windows in
    /// `stripping` lose their ordinary Space only if this batch conceals them.
    func apply(show: [UInt32], on displays: [UInt32: CGDirectDisplayID], hide: [UInt32], stripping: Set<UInt32>,
               done: @escaping @MainActor (Outcome, Timing) -> Void) {
        let canConceal = canConceal
        let hide = canConceal ? hide : []
        for window in hide { batchesConcealing[window, default: 0] += 1 }
        let store = self.store
        let submitted = ContinuousClock.now
        bridge.async {
            let started = ContinuousClock.now
            let (confirmed, sent, barrier, stripped) = store.apply(show: show, on: displays, hide: hide, stripping: stripping)
            let applied = ContinuousClock.now
            let outcome = confirmed ? nil : store.recover(keepingAnimationSpaces: true)
            let concealed = store.concealed
            let finished = ContinuousClock.now
            var timing = Timing(queued: started - submitted, sent: (sent ?? applied) - started,
                                confirmed: applied - (sent ?? applied), recovered: finished - applied, barrier: barrier,
                                stripped: stripped)
            onMain {
                timing.returned = .now - finished
                self.concealed = concealed
                for window in hide {
                    self.batchesConcealing[window]! -= 1
                    if self.batchesConcealing[window] == 0 { self.batchesConcealing[window] = nil }
                }
                if let outcome { self.report(outcome) }
                done(confirmed ? (canConceal ? .confirmed : .revealedOnly) : .failed, timing)
            }
        }
    }

    /// Forgets windows that left the holding Space on their own, as a deselected native tab
    /// does; kept, a batch would fail to find them there (docs/tree.md).
    func forget(_ windows: [UInt32]) {
        let store = self.store
        bridge.async {
            store.forget(windows)
            let concealed = store.concealed
            onMain { self.concealed = concealed }
        }
    }

    func restoreAll() {
        let store = self.store
        bridge.async {
            let outcome = store.recover(keepingAnimationSpaces: true)
            let concealed = store.concealed
            onMain {
                self.concealed = concealed
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
}

/// Used only on the bridge queue.
private final class HidingStore: @unchecked Sendable {
    private let record: RecordFile
    private var state: RecoveryRecord?
    private var space: UInt64 = 0
    private var ledger = ConcealLedger()
    private var loaded = false
    /// Read on the main actor too.
    let history = Mutex(ConcealHistory<ContinuousClock.Instant>())

    init(record: RecordFile) { self.record = record }

    var concealed: Set<UInt32> { Set(ledger.entries.keys) }

    /// False while a recorded Space cannot be read: nothing is concealed or revealed until
    /// its state is known.
    private func load() -> Bool {
        if loaded { return true }
        guard let windowServer = ProcessIdentity.windowServer() else { return false }
        guard let onFile = record.read(), onFile.windowServer == windowServer else {
            state = RecoveryRecord(windowServer: windowServer, manager: .current)
            space = 0
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
        ledger = rebuilt
        loaded = true
        return true
    }

    /// `sent` is nil when the batch stopped before sending, `barrier` nil when it read nothing.
    func apply(show: [UInt32], on displays: [UInt32: CGDirectDisplayID], hide: [UInt32],
               stripping: Set<UInt32>) -> (confirmed: Bool, sent: ContinuousClock.Instant?, barrier: Bool?, stripped: Int) {
        guard let (batch, sent) = send(show: show, on: displays, hide: hide, stripping: stripping) else { return (false, nil, nil, 0) }
        let touched = batch.touched
        guard let any = touched.first else { return (true, sent, nil, batch.strip.count) }
        // A Space whose read fails is left out, which proves nothing.
        func done() -> Bool {
            var members: [UInt64: Set<UInt32>] = [:]
            for space in touched {
                if let list = SkyLight.windows(in: space) { members[space] = Set(list) }
            }
            return batch.isDone(members: members)
        }
        // Direct reads show the operations once WindowServer applied them; the barrier also
        // waits behind WindowManager.app, so it goes only once the direct reads run out of time
        // (docs/hiding.md).
        let deadline = ContinuousClock.now + Self.directReadsBeforeBarrier
        var confirmed = done()
        while !confirmed && ContinuousClock.now < deadline {
            usleep(100)
            confirmed = done()
        }
        if !confirmed {
            guard kosmos_barrier(any), done() else { return (false, sent, true, batch.strip.count) }
        }
        ledger.commit(batch, into: space)
        return (true, sent, !confirmed, batch.strip.count)
    }

    private static let directReadsBeforeBarrier: Duration = .milliseconds(10)

    private func send(show: [UInt32], on showDisplays: [UInt32: CGDirectDisplayID], hide: [UInt32],
                      stripping: Set<UInt32>) -> (ConcealLedger.Batch, ContinuousClock.Instant)? {
        guard load() else { return nil }
        // A window with no row, or new to the record with no owner, is left out. Ceiling: a
        // failed row query leaves every window to hide on screen; docs/hiding.md has the upgrade.
        let rows = Dictionary(SkyLight.rows(hide).map { ($0.id, $0) }) { first, _ in first }
        let recorded = Set(state!.windows.map(\.id))
        var owners: [UInt32: ProcessIdentity] = [:]
        for (id, row) in rows where !recorded.contains(id) { owners[id] = ProcessIdentity.of(row.pid) }
        let hide = hide.filter { recorded.contains($0) ? rows[$0] != nil : owners[$0] != nil }
        let fresh = Set(hide).filter { ledger.entries[$0] == nil }
        if !fresh.isEmpty, !prepare(Array(fresh), owners: owners) { return nil }
        let batch = ledger.batch(show: show, hide: hide, stripping: stripping, into: space,
                                 hasOrdinarySpace: Self.hasOrdinarySpace)
        // Adds land before any removal: a window removed from its only Space lands on the
        // active Space, maybe a fullscreen one. Only a batch that adds pays the barrier and
        // the display read (docs/hiding.md).
        var removals = batch.removals
        if !batch.adds.isEmpty {
            let displays = Displays.current()
            let original = Dictionary(state!.windows.map { ($0.id, $0.originalSpace) }, uniquingKeysWith: { a, _ in a })
            var destinations: [UInt64: [UInt32]] = [:]
            for window in batch.adds {
                guard let destination = displays.ordinarySpace(on: showDisplays[window], original: original[window]) else { return nil }
                destinations[destination, default: []].append(window)
            }
            for (destination, windows) in destinations { Self.add(windows, to: destination, exclusively: true) }
            guard let held = batch.removals.keys.first, kosmos_barrier(held) else { return nil }
            removals = batch.removals(landed: displays.isInOrdinarySpace)
        }
        history.withLock { $0.changed(Array(removals.values.joined()), concealed: false, at: .now) }
        for (from, windows) in removals {
            var ids = windows
            kosmos_remove_windows(from, &ids, ids.count)
        }
        history.withLock { $0.changed(batch.fresh, concealed: true, at: .now) }
        Self.add(batch.fresh.filter { !batch.strip.contains($0) }, to: space, exclusively: false)
        Self.add(batch.strip, to: space, exclusively: true)
        return (batch, .now)
    }

    /// An exclusive add takes the windows out of their other managed Spaces.
    private static func add(_ windows: [UInt32], to space: UInt64, exclusively: Bool) {
        kosmos_add_windows(space, windows, windows.count, exclusively)
    }

    func forgetClosed(_ window: UInt32) {
        guard load() else { return }
        forget(ledger.departed([window], members: SkyLight.windows(in:),
                               settled: { SkyLight.rows([$0]).isEmpty || SkyLight.spaces(of: $0)?.isEmpty == false }))
    }

    func forget(_ windows: [UInt32]) {
        guard load() else { return }
        ledger.forget(windows)
        history.withLock { history in windows.forEach { history.forget($0) } }
        guard var next = state, next.windows.contains(where: { windows.contains($0.id) }) else { return }
        next.windows.removeAll { windows.contains($0.id) }
        if record.publish(next) { state = next }
    }

    /// Records the holding Space before any window enters it, and each window before its
    /// first hide.
    private func prepare(_ windows: [UInt32], owners: [UInt32: ProcessIdentity]) -> Bool {
        var next = state!
        var created: UInt64 = 0
        if space == 0 {
            created = kosmos_holding_create()
            guard created != 0 else {
                hidingLog.error("holding Space not created")
                return false
            }
            next.spaces.append(created)
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
            let alive = Set(SkyLight.rows(next.windows.map(\.id)).map(\.id))
            guard let pruned = next.pruned(alive: alive, keeping: Set(ledger.entries.keys).union(windows), seen: new) else {
                hidingLog.error("the recorded windows could not be read; not concealing")
                return abandon(created)
            }
            guard record.publish(pruned) else {
                hidingLog.error("the recovery record is full; not concealing")
                return abandon(created)
            }
            next = pruned
        }
        state = next
        if created != 0 { space = created }
        return true
    }

    /// Destroys a Space created for a change never published, which holds no window.
    private func abandon(_ created: UInt64) -> Bool {
        if created != 0 { kosmos_space_destroy(created) }
        return false
    }

    /// Records the Spaces windows slide in before any window enters them.
    func createAnimationSpaces(_ count: Int, level: Int32) -> [UInt64] {
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
    func recover(keepingAnimationSpaces keeping: Bool) -> Recovery.Outcome {
        let outcome = Recovery.run(file: record, keepingAnimationSpaces: keeping)
        hidingLog.notice("recovery: \(String(describing: outcome), privacy: .public)")
        history.withLock { $0.forgetAll() }   // recovery's reveals are not in the history
        loaded = false
        if !load() {
            // Every batch fails at load() and recovers again, so this ledger decides nothing.
            ledger = ConcealLedger()
        }
        return outcome
    }

    /// kosmos_window_spaces leaves out the holding Space. A fullscreen Space counts too: an add
    /// to an ordinary Space would take the window out of it.
    private static func hasOrdinarySpace(_ window: UInt32) -> Bool {
        SkyLight.spaces(of: window)?.isEmpty == false
    }
}
