import CKosmos
import Foundation
import KosmosCore
import KosmosRecovery
import KosmosSkyLight
import Synchronization
import os

private let hidingLog = Logger(subsystem: "io.github.st-eez.kosmos", category: "hiding")

/// Conceals windows of hidden workspaces in one holding Space
/// (docs/overview.md, section 4.3, and docs/hiding.md). The record, the Space and every recovery
/// run on the bridge queue, so a recovery never races a batch still in flight.
@MainActor
final class Hiding {
    /// Where a batch's time went, for the switch log: waiting behind earlier bridge jobs,
    /// preparing and sending its operations, confirming them, the recovery after a batch
    /// that failed, and the way back to the main actor.
    struct Timing: Sendable {
        var queued = Duration.zero, sent = Duration.zero, confirmed = Duration.zero
        var recovered = Duration.zero, returned = Duration.zero
        /// The confirmation needed the barrier because direct reads did not show the batch
        /// done in time; nil when the batch read nothing.
        var barrier: Bool?
        /// The windows the batch stripped of their ordinary Space as it concealed them.
        var stripped = 0
    }

    enum Outcome: Sendable {
        case confirmed
        /// Without a ready guardian, or on a macOS that lacks a bridged operation, nothing is
        /// concealed; windows were only revealed.
        case revealedOnly
        /// A bridged operation was not confirmed and recovery ran; windows it could not
        /// restore stay concealed and recorded.
        case failed
    }

    private let guardian: Guardian
    private let canHide = SkyLight.missingBridgedOperation == nil
    private let bridge = DispatchQueue(label: "kosmos.bridge", qos: .userInteractive)
    private let store: HidingStore
    /// The windows concealed after the last batch the bridge finished, for focus reports.
    /// The bridge queue's ledger is the truth; this copy only follows it.
    private var concealed: Set<UInt32> = []
    /// The windows that batches in flight conceal, each with how many batches do.
    private var concealing: [UInt32: Int] = [:]

    /// Called with a description when concealed windows could not all be restored, and with
    /// nil once they have been.
    var onProblem: (@MainActor (String?) -> Void)?

    init(record: RecordFile, guardian: Guardian) {
        self.guardian = guardian
        store = HidingStore(record: record)
        guardian.onUnavailable = { [weak self] in self?.restoreAll() }
    }

    func isConcealed(_ window: UInt32) -> Bool { concealed.contains(window) }

    /// Whether the window is concealed or a batch in flight conceals it, which
    /// `isConcealed` reads only once the batch finishes.
    func isConcealedOrConcealing(_ window: UInt32) -> Bool { concealed.contains(window) || concealing[window] != nil }

    /// Whether the guardian would recover windows now, should Kosmos die: windows slide
    /// through the pool's Spaces only then (Slides).
    var guardianReady: Bool { guardian.isReady }

    /// Creates `count` Spaces for windows to slide in at `level` on the bridge queue, each
    /// recorded before any window enters it, and hands the ones created to `done`.
    func createAnimationSpaces(_ count: Int, level: Int32, done: @escaping @MainActor ([UInt64]) -> Void) {
        let store = self.store
        bridge.async {
            let spaces = store.createAnimationSpaces(count, level: level)
            DispatchQueue.main.async { MainActor.assumeIsolated { done(spaces) } }
        }
    }

    /// Whether the window was concealed when a report was stamped, judged by when the bridge
    /// last sent its conceal or reveal (ConcealHistory).
    func wasConcealed(_ window: UInt32, at stamp: ContinuousClock.Instant) -> Bool {
        store.history.withLock { $0.wasConcealed(window, at: stamp, now: concealed.contains(window)) }
    }

    /// Forgets a window that closed: its history at once, and on the bridge queue its entries
    /// in the ledger and the record, once its concealing Space no longer lists it, or for a
    /// window the ledger does not hold, once its row is gone or it has a Space. Kept, the
    /// record would fill with closed windows and every conceal would stop. A window still
    /// listed stays recorded, as one that only stopped being managed or that a failed read
    /// took for closed, so recovery restores it.
    func forgetClosed(_ window: UInt32) {
        store.history.withLock { $0.forget(window) }
        let store = self.store
        bridge.async {
            store.forgetClosed(window)
            let concealed = store.concealed
            DispatchQueue.main.async { MainActor.assumeIsolated { self.concealed = concealed } }
        }
    }

    /// Reveals `show`, then conceals `hide`, then confirms both, on the bridge queue.
    /// `displays` holds the display each revealed window's workspace is on. The windows of
    /// `hide` in `stripping` lose their ordinary Space if they are concealed now; the others
    /// keep it. Concealing needs a ready guardian; revealing does not.
    func apply(show: [UInt32], on displays: [UInt32: CGDirectDisplayID], hide: [UInt32], stripping: Set<UInt32>,
               done: @escaping @MainActor (Outcome, Timing) -> Void) {
        let canConceal = canHide && guardian.isReady
        let hide = canConceal ? hide : []
        for window in hide { concealing[window, default: 0] += 1 }
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
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    timing.returned = .now - finished
                    self.concealed = concealed
                    for window in hide {
                        self.concealing[window]! -= 1
                        if self.concealing[window] == 0 { self.concealing[window] = nil }
                    }
                    if let outcome { self.report(outcome) }
                    done(confirmed ? (canConceal ? .confirmed : .revealedOnly) : .failed, timing)
                }
            }
        }
    }

    /// Forgets windows that left the holding Space on their own, as a native tab does when
    /// it is deselected (kosmos-probe tabs). The ledger would otherwise take the tab for
    /// concealed when it is selected again, and a batch would fail to find it there. The
    /// record forgets it too, or recovery would add the deselected tab to a Space.
    func forget(_ windows: [UInt32]) {
        let store = self.store
        bridge.async {
            store.forget(windows)
            let concealed = store.concealed
            DispatchQueue.main.async { MainActor.assumeIsolated { self.concealed = concealed } }
        }
    }

    /// Restores every concealed window, as when hiding stops for good.
    func restoreAll() {
        let store = self.store
        bridge.async {
            let outcome = store.recover(keepingAnimationSpaces: true)
            let concealed = store.concealed
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.concealed = concealed
                    self.report(outcome)
                }
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

    /// Waits for queued batches, then restores every concealed window and destroys every
    /// Space, the ones windows slide in too. For quit.
    func recoverNow() -> Recovery.Outcome {
        let store = self.store
        return bridge.sync { store.recover(keepingAnimationSpaces: false) }
    }
}

/// The record, its copy in memory, the holding Space and the ledger, used only on the
/// bridge queue.
private final class HidingStore: @unchecked Sendable {
    private let record: RecordFile
    private var state: RecoveryRecord?
    private var space: UInt64 = 0
    private var ledger = ConcealLedger()
    /// Whether the record on file and the ledger it implies are loaded.
    private var loaded = false
    /// When each window's conceal or reveal was last sent, read on the main actor too.
    let history = Mutex(ConcealHistory<ContinuousClock.Instant>())

    init(record: RecordFile) { self.record = record }

    var concealed: Set<UInt32> { Set(ledger.entries.keys) }

    /// Loads the record on file, and the ledger for the concealed windows its Spaces still
    /// hold, as after an incomplete recovery. False while a Space cannot be read: nothing may
    /// be concealed or revealed until its state is known.
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
        // A Space that no longer exists holds nothing and leaves the record.
        let read = SpaceMembers.read(onFile.spaces, of: onFile)
        guard let rebuilt = ConcealLedger.rebuilt(members: read.members.mapValues { Optional($0) }) else { return false }
        state = onFile
        state!.manager = .current
        state!.spaces.removeAll { read.gone.contains($0) }
        // The newest recorded Space is used again rather than adding one per attempt, unless
        // it may have been sent a destroy.
        space = onFile.reusableSpace(members: read.members) ?? 0
        ledger = rebuilt
        loaded = true
        return true
    }

    /// Whether the batch was confirmed, when it had sent its operations (nil if it stopped
    /// before), whether its confirmation needed the barrier (nil if it read nothing), and
    /// how many windows it stripped.
    func apply(show: [UInt32], on displays: [UInt32: CGDirectDisplayID], hide: [UInt32],
               stripping: Set<UInt32>) -> (confirmed: Bool, sent: ContinuousClock.Instant?, barrier: Bool?, stripped: Int) {
        guard let (batch, sent) = send(show: show, on: displays, hide: hide, stripping: stripping) else { return (false, nil, nil, 0) }
        let touched = batch.touched
        guard let any = touched.first else { return (true, sent, nil, batch.strip.count) }
        /// Whether the touched Spaces show the batch done. A failed read leaves its Space out,
        /// which proves nothing.
        func done() -> Bool {
            var members: [UInt64: Set<UInt32>] = [:]
            for space in touched {
                if let list = SkyLight.windows(in: space) { members[space] = Set(list) }
            }
            return batch.isDone(members: members)
        }
        // Reads on Kosmos's own connection show the operations once WindowServer applied
        // them, usually within a millisecond. A bridged read also waits behind
        // WindowManager.app, which rebuilds its window model when a window joins or leaves
        // an ordinary Space, as a reveal that adds does. So the batch reads directly
        // for up to readBound, and only then sends the barrier, after which the bridge has
        // run every operation and one read decides.
        let deadline = ContinuousClock.now + Self.readBound
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

    /// How long a batch reads the Spaces directly before it sends the barrier.
    private static let readBound: Duration = .milliseconds(10)

    /// Sends a batch's operations: adds, removals, then conceals. Nil when it stops before,
    /// with the batch and the time it had sent them otherwise.
    private func send(show: [UInt32], on showDisplays: [UInt32: CGDirectDisplayID], hide: [UInt32],
                      stripping: Set<UInt32>) -> (ConcealLedger.Batch, ContinuousClock.Instant)? {
        guard load() else { return nil }
        // A window closed since the batch was planned has no row, and one new to the record
        // whose app quit can keep its row after its process is gone, so its owner reads as
        // nil. Neither has anything to conceal or can be recorded, so the batch leaves it out
        // (docs/hiding.md). A failed row query reads as every window gone and leaves the
        // windows to hide on screen. If that shows up, the upgrade is for SkyLight.rows to
        // return nil for a failed query, and for the batch to keep its whole hide set then.
        let rows = Dictionary(SkyLight.rows(hide).map { ($0.id, $0) }) { first, _ in first }
        let recorded = Set(state!.windows.map(\.id))
        var owners: [UInt32: ProcessIdentity] = [:]
        for (id, row) in rows where !recorded.contains(id) { owners[id] = ProcessIdentity.of(row.pid) }
        let hide = hide.filter { recorded.contains($0) ? rows[$0] != nil : owners[$0] != nil }
        let fresh = Set(hide).filter { ledger.entries[$0] == nil }
        if !fresh.isEmpty, !prepare(Array(fresh), owners: owners) { return nil }
        let batch = ledger.batch(show: show, hide: hide, stripping: stripping, into: space,
                                 hasOrdinarySpace: Self.hasOrdinarySpace)
        // Adds land before any removal is sent: a window removed from its only Space lands on
        // whichever Space is active, which can be a native fullscreen one. The add's return
        // says only that it was sent, so a barrier and a read confirm it, about 1.3 ms, and
        // the displays are read, up to 7 ms on the development Mac, only in a batch that adds.
        var removals = batch.removals
        if !batch.adds.isEmpty {
            let displays = Displays.current()
            let original = Dictionary(state!.windows.map { ($0.id, $0.originalSpace) }, uniquingKeysWith: { a, _ in a })
            var destinations: [UInt64: [UInt32]] = [:]
            for window in batch.adds {
                guard let destination = displays.ordinarySpace(on: showDisplays[window], original: original[window]) else { return nil }
                destinations[destination, default: []].append(window)
            }
            for (destination, windows) in destinations {
                var ids = windows
                kosmos_add_windows(destination, &ids, ids.count, true)
            }
            guard let held = batch.removals.keys.first, kosmos_barrier(held) else { return nil }
            removals = batch.removals(landed: displays.isInOrdinarySpace)
        }
        history.withLock { $0.changed(Array(removals.values.joined()), concealed: false, at: .now) }
        for (from, windows) in removals {
            var ids = windows
            kosmos_remove_windows(from, &ids, ids.count)
        }
        history.withLock { $0.changed(batch.fresh, concealed: true, at: .now) }
        // An add that keeps their other Spaces, the ordinary one included, and for the
        // windows to strip one that takes them out of their ordinary Space.
        var ids = batch.fresh.filter { !batch.strip.contains($0) }
        kosmos_add_windows(space, &ids, ids.count, false)
        ids = batch.strip
        kosmos_add_windows(space, &ids, ids.count, true)
        return (batch, .now)
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
    /// first hide, with its owner in `owners`. A change is kept only once it is published.
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
            // The slot is full: drop records of windows that no longer exist, keeping the
            // concealed ones and this batch's.
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

    /// Destroys a Space created for a change that was never published. It holds no window.
    private func abandon(_ created: UInt64) -> Bool {
        if created != 0 { kosmos_space_destroy(created) }
        return false
    }

    /// Creates Spaces for windows to slide in, recorded before any window enters them.
    /// Returns the ones created, none when the record cannot take them.
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

    /// Runs recovery, then loads the ledger again from what the record still names.
    /// `keepingAnimationSpaces`: the running Kosmos goes on sliding windows through them.
    @discardableResult
    func recover(keepingAnimationSpaces keeping: Bool) -> Recovery.Outcome {
        let outcome = Recovery.run(file: record, keepingAnimationSpaces: keeping)
        hidingLog.notice("recovery: \(String(describing: outcome), privacy: .public)")
        history.withLock { $0.forgetAll() }   // recovery restores windows unrecorded
        loaded = false
        if !load() {
            // Unknown: every batch fails at load() and runs recovery again, so this empty
            // ledger is never used to decide a reveal or a conceal.
            ledger = ConcealLedger()
        }
        return outcome
    }

    /// Whether the window has a Space besides the holding Space, which the list leaves out,
    /// so a removal from the holding Space leaves it where it was. Any listed Space counts, a
    /// native fullscreen one included: an add to an ordinary Space would take the window out
    /// of it.
    private static func hasOrdinarySpace(_ window: UInt32) -> Bool {
        SkyLight.spaces(of: window)?.isEmpty == false
    }
}
