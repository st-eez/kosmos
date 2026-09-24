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
    /// How a window leaves the screen. An app's selected window keeps its ordinary Space
    /// membership so Command-Tab still picks it; the app's other concealed windows lose it.
    typealias Conceal = ConcealLedger.Kind

    enum Outcome: Sendable {
        case confirmed
        /// Without a ready guardian nothing is concealed; windows were only revealed.
        case revealedOnly
        /// A bridged operation was not confirmed and every concealed window was restored.
        case failed
    }

    private let guardian: Guardian
    private let bridge = DispatchQueue(label: "kosmos.bridge", qos: .userInteractive)
    private let store: HidingStore
    /// The windows concealed after the last batch the bridge finished, for focus reports.
    /// The bridge queue's ledger is the truth; this copy only follows it.
    private var concealed: Set<UInt32> = []

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
            if !confirmed { store.recover() }
            let concealed = store.concealed
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.concealed = concealed
                    done(confirmed ? (canConceal ? .confirmed : .revealedOnly) : .failed)
                }
            }
        }
    }

    /// Restores every concealed window, as when hiding stops for good.
    func restoreAll() {
        let store = self.store
        bridge.async {
            store.recover()
            let concealed = store.concealed
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.concealed = concealed }
            }
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

    init(record: RecordFile) { self.record = record }

    var concealed: Set<UInt32> { Set(ledger.entries.keys) }

    func apply(show: [UInt32], hide: [UInt32: ConcealLedger.Kind]) -> Bool {
        let fresh = hide.keys.filter { ledger.entries[$0] == nil }
        if !fresh.isEmpty, !prepare(fresh) { return false }
        let batch = ledger.batch(show: show, hide: hide, into: space)
        for (from, windows) in batch.removals {
            var ids = windows
            kosmos_remove_windows(from, &ids, ids.count)
        }
        if !batch.moves.isEmpty {
            guard let destination = Displays.current().mainCurrentSpace else { return false }
            var ids = batch.moves
            kosmos_add_windows(destination, &ids, ids.count, true)
        }
        var ids = batch.keep
        kosmos_add_windows(space, &ids, ids.count, false)
        ids = batch.strip
        kosmos_add_windows(space, &ids, ids.count, true)
        // One barrier after every operation of the batch: the bridge runs them in order.
        let touched = Set(batch.mustBeIn.values).union(batch.mustHaveLeft.values)
        guard let any = touched.first else { return true }
        guard kosmos_barrier(any) else { return false }
        var members: [UInt64: Set<UInt32>] = [:]
        for space in touched {
            // A failed read proves nothing, so it fails the batch.
            guard let list = kosmos_space_windows(space) as? [UInt32] else { return false }
            members[space] = Set(list)
        }
        let hidden = batch.mustBeIn.allSatisfy { members[$0.value]!.contains($0.key) }
        let shown = batch.mustHaveLeft.allSatisfy { !members[$0.value]!.contains($0.key) }
        guard hidden && shown else { return false }
        ledger.commit(batch, into: space)
        return true
    }

    /// Records the holding Space before any window enters it, and each window before its
    /// first hide. A change is kept only once it is published.
    private func prepare(_ windows: [UInt32]) -> Bool {
        if state == nil {
            guard let windowServer = ProcessIdentity.windowServer() else { return false }
            // Spaces an incomplete recovery left on file stay recorded, and the newest is
            // used again rather than adding one per attempt.
            if let onFile = record.read(), onFile.windowServer == windowServer {
                state = onFile
                state!.manager = .current
                space = onFile.spaces.last ?? 0
            } else {
                state = RecoveryRecord(windowServer: windowServer, manager: .current)
            }
        }
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

    /// Runs recovery, then rebuilds the ledger from the windows it could not restore.
    @discardableResult
    func recover() -> Recovery.Outcome {
        let outcome = Recovery.run(file: record)
        hidingLog.notice("recovery: \(String(describing: outcome), privacy: .public)")
        // Start over from the file: empty after a full recovery, the leftovers otherwise.
        state = nil
        space = 0
        var entries: [UInt32: ConcealLedger.Entry] = [:]
        for left in record.read()?.spaces ?? [] {
            for window in kosmos_space_windows(left) as? [UInt32] ?? [] {
                let ordinary = !((kosmos_window_spaces(window) as? [UInt64]) ?? []).isEmpty
                entries[window] = .init(kind: ordinary ? .keepOrdinary : .exclusive, space: left)
            }
        }
        ledger = ConcealLedger(entries: entries)
        return outcome
    }

    func recoverOutcome() -> Recovery.Outcome { recover() }
}
