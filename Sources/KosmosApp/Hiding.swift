import CKosmos
import Foundation
import KosmosCore
import KosmosRecovery
import KosmosSkyLight
import os

private let hidingLog = Logger(subsystem: "io.github.st-eez.kosmos", category: "hiding")

/// Conceals windows of hidden workspaces in one holding Space (DESIGN.md, sections 4.3 and
/// 5.3). The record, the Space and every recovery run on the bridge queue, so a recovery
/// never races a batch still in flight.
@MainActor
final class Hiding {
    /// How a window leaves the screen. An app's most recently used window keeps its ordinary
    /// Space membership so Command-Tab still picks it; the app's other concealed windows
    /// lose it.
    typealias Conceal = ConcealLedger.Kind

    enum Outcome: Sendable {
        case confirmed
        /// Without a ready guardian nothing is concealed; windows were only revealed.
        case revealedOnly
        /// A bridged operation was not confirmed and recovery ran; windows it could not
        /// restore stay concealed and recorded.
        case failed
    }

    private let guardian: Guardian
    private let bridge = DispatchQueue(label: "kosmos.bridge", qos: .userInteractive)
    private let store: HidingStore
    /// The windows concealed after the last batch the bridge finished, for focus reports.
    /// The bridge queue's ledger is the truth; this copy only follows it.
    private var concealed: Set<UInt32> = []

    /// Called with a description when concealed windows could not all be restored, and with
    /// nil once they have been.
    var onProblem: (@MainActor (String?) -> Void)?

    init(record: RecordFile, guardian: Guardian) {
        self.guardian = guardian
        store = HidingStore(record: record)
        guardian.onUnavailable = { [weak self] in self?.restoreAll() }
    }

    func isConcealed(_ window: UInt32) -> Bool { concealed.contains(window) }

    /// Reveals `show`, then conceals `hide`, then reads the barrier, on the bridge queue.
    /// Concealing needs a ready guardian; revealing does not.
    func apply(show: [UInt32], hide: [UInt32: Conceal], done: @escaping @MainActor (Outcome) -> Void) {
        let canConceal = guardian.isReady
        let hide = canConceal ? hide : [:]
        let store = self.store
        bridge.async {
            let confirmed = store.apply(show: show, hide: hide)
            let outcome = confirmed ? nil : store.recover()
            let concealed = store.concealed
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.concealed = concealed
                    if let outcome { self.report(outcome) }
                    done(confirmed ? (canConceal ? .confirmed : .revealedOnly) : .failed)
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

    /// Leaves `keep` the one concealed window of `windows`, an app's windows, with an
    /// ordinary Space, after the app keyed it. Runs as its own bridge job, never inside a
    /// switch's batch, and needs no barrier: a reveal reads the membership it finds.
    func keepOrdinary(_ keep: UInt32, of windows: [UInt32]) {
        let store = self.store
        bridge.async { store.keepOrdinary(keep, of: windows) }
    }

    /// Restores every concealed window, as when hiding stops for good.
    func restoreAll() {
        let store = self.store
        bridge.async {
            let outcome = store.recover()
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

    /// Waits for queued batches, then restores every concealed window. For quit.
    func recoverNow() -> Recovery.Outcome {
        let store = self.store
        return bridge.sync { store.recoverOutcome() }
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

    init(record: RecordFile) { self.record = record }

    var concealed: Set<UInt32> { Set(ledger.entries.keys) }

    /// Loads the record on file, and the ledger for the windows its Spaces still hold, as
    /// after an incomplete recovery. False while a Space cannot be read: nothing may be
    /// concealed or revealed until its state is known.
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
        let read = SpaceMembers.read(onFile.spaces)
        guard let rebuilt = ConcealLedger.rebuilt(members: read.members.mapValues { Optional($0) }) else { return false }
        state = onFile
        state!.manager = .current
        state!.spaces.removeAll { read.gone.contains($0) }
        // The newest recorded Space is used again rather than adding one per attempt.
        space = onFile.spaces.last ?? 0
        ledger = rebuilt
        loaded = true
        return true
    }

    func apply(show: [UInt32], hide: [UInt32: ConcealLedger.Kind]) -> Bool {
        guard load() else { return false }
        let fresh = hide.keys.filter { ledger.entries[$0] == nil }
        if !fresh.isEmpty, !prepare(fresh) { return false }
        let batch = ledger.batch(show: show, hide: hide, into: space, hasOrdinarySpace: Self.hasOrdinarySpace)
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
                guard let destination = displays.ordinarySpace(original: original[window]) else { return false }
                destinations[destination, default: []].append(window)
            }
            for (destination, windows) in destinations {
                var ids = windows
                kosmos_add_windows(destination, &ids, ids.count, true)
            }
            guard let held = batch.removals.keys.first, kosmos_barrier(held) else { return false }
            removals = batch.removals(landed: displays.isInOrdinarySpace)
        }
        for (from, windows) in removals {
            var ids = windows
            kosmos_remove_windows(from, &ids, ids.count)
        }
        var ids = batch.keep
        kosmos_add_windows(space, &ids, ids.count, false)
        ids = batch.strip
        kosmos_add_windows(space, &ids, ids.count, true)
        // One barrier after every operation of the batch: the bridge runs them in order.
        let touched = Set(batch.mustBeIn.values).union(batch.removals.keys)
        guard let any = touched.first else { return true }
        guard kosmos_barrier(any) else { return false }
        var members: [UInt64: Set<UInt32>] = [:]
        for space in touched {
            // A failed read proves nothing, so it fails the batch.
            guard let list = kosmos_space_windows(space) as? [UInt32] else { return false }
            members[space] = Set(list)
        }
        let hidden = batch.mustBeIn.allSatisfy { members[$0.value]!.contains($0.key) }
        let shown = batch.removals.allSatisfy { space, windows in windows.allSatisfy { !members[space]!.contains($0) } }
        guard hidden && shown else { return false }
        ledger.commit(batch, into: space)
        return true
    }

    func keepOrdinary(_ keep: UInt32, of windows: [UInt32]) {
        guard load() else { return }
        let change = ledger.membership(of: windows, keep: keep, hasOrdinarySpace: Self.hasOrdinarySpace)
        // An add that keeps the concealing Space: the window stays concealed.
        if !change.restore.isEmpty {
            let original = state!.windows.first { $0.id == keep }?.originalSpace
            if let destination = Displays.current().ordinarySpace(original: original) {
                var ids = change.restore
                kosmos_add_windows(destination, &ids, ids.count, false)
            }
        }
        // An exclusive add to the Space that already conceals them takes their ordinary one.
        for (space, windows) in change.strip {
            var ids = windows
            kosmos_add_windows(space, &ids, ids.count, true)
        }
    }

    func forget(_ windows: [UInt32]) {
        guard load() else { return }
        ledger.forget(windows)
        guard var next = state, next.windows.contains(where: { windows.contains($0.id) }) else { return }
        next.windows.removeAll { windows.contains($0.id) }
        if record.publish(next) { state = next }
    }

    /// Records the holding Space before any window enters it, and each window before its
    /// first hide. A change is kept only once it is published.
    private func prepare(_ windows: [UInt32]) -> Bool {
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
        let rows = Dictionary(uniqueKeysWithValues: SkyLight.rows(new).map { ($0.id, $0) })
        for id in new {
            guard let row = rows[id], let owner = ProcessIdentity.of(row.pid) else { return abandon(created) }
            let original = (kosmos_window_spaces(id) as? [UInt64])?.first ?? 0
            next.windows.append(.init(id: id, owner: owner, originalSpace: original))
        }
        if !record.publish(next) {
            // The slot is full: drop records of windows that no longer exist.
            let alive = Set(SkyLight.rows(next.windows.map(\.id)).map(\.id))
            next.windows.removeAll { !alive.contains($0.id) }
            guard record.publish(next) else {
                hidingLog.error("the recovery record is full; not concealing")
                return abandon(created)
            }
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

    /// Runs recovery, then loads the ledger again from what the record still names.
    @discardableResult
    func recover() -> Recovery.Outcome {
        let outcome = Recovery.run(file: record)
        hidingLog.notice("recovery: \(String(describing: outcome), privacy: .public)")
        loaded = false
        if !load() {
            // Unknown: every batch fails at load() and runs recovery again, so this empty
            // ledger is never used to decide a reveal or a conceal.
            ledger = ConcealLedger()
        }
        return outcome
    }

    func recoverOutcome() -> Recovery.Outcome { recover() }

    /// Whether the window has a Space besides the holding Space, which the list leaves out,
    /// so a removal from the holding Space leaves it where it was. Any listed Space counts, a
    /// native fullscreen one included: an add to an ordinary Space would take the window out
    /// of it.
    private static func hasOrdinarySpace(_ window: UInt32) -> Bool {
        !((kosmos_window_spaces(window) as? [UInt64]) ?? []).isEmpty
    }
}
