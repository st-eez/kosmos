import CKosmos
import Foundation
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
    enum Conceal: Sendable { case keepOrdinary, exclusive }

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
    /// How each concealed window was concealed; revealing it undoes exactly that.
    private var concealed: [UInt32: Conceal] = [:]

    init(record: RecordFile, guardian: Guardian) {
        self.guardian = guardian
        store = HidingStore(record: record)
        guardian.onUnavailable = { [weak self] in self?.restoreAll() }
    }

    func isConcealed(_ window: UInt32) -> Bool { concealed[window] != nil }

    /// Reveals `show`, then conceals `hide`, then reads the barrier, on the bridge queue.
    /// Concealing needs a ready guardian; revealing does not.
    func apply(show: [UInt32], hide: [UInt32: Conceal], done: @escaping @MainActor (Outcome) -> Void) {
        let reveal = show.filter { concealed[$0] == .keepOrdinary }
        let move = show.filter { concealed[$0] == .exclusive }
        let canConceal = guardian.isReady
        // A window already concealed keeps its membership, so it keeps its kind too.
        let fresh = canConceal ? hide.filter { concealed[$0.key] == nil } : [:]
        let expectHidden = canConceal ? Array(hide.keys) : []
        for id in show { concealed[id] = nil }
        concealed.merge(fresh) { old, _ in old }

        let store = self.store
        bridge.async {
            let confirmed = store.apply(reveal: reveal, move: move, conceal: fresh, expectShown: show, expectHidden: expectHidden)
            let left = confirmed ? nil : store.recover()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let left { self.concealed = left.reduce(into: [:]) { $0[$1] = .exclusive } }
                    done(confirmed ? (canConceal ? .confirmed : .revealedOnly) : .failed)
                }
            }
        }
    }

    /// Restores every concealed window, as when hiding stops for good.
    func restoreAll() {
        let store = self.store
        bridge.async {
            let left = store.recover()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.concealed = left.reduce(into: [:]) { $0[$1] = .exclusive } }
            }
        }
    }

    /// Waits for queued batches, then restores every concealed window. For quit.
    func recoverNow() -> Recovery.Outcome {
        let store = self.store
        return bridge.sync { store.recoverOutcome() }
    }
}

/// The record, its copy in memory and the holding Space, used only on the bridge queue.
private final class HidingStore: @unchecked Sendable {
    private let record: RecordFile
    private var state: RecoveryRecord?
    private var space: UInt64 = 0

    init(record: RecordFile) { self.record = record }

    func apply(reveal: [UInt32], move: [UInt32], conceal: [UInt32: Hiding.Conceal],
               expectShown: [UInt32], expectHidden: [UInt32]) -> Bool {
        if !conceal.isEmpty, !prepare(Array(conceal.keys)) { return false }
        guard space != 0 else { return reveal.isEmpty && move.isEmpty }
        var ids = reveal
        kosmos_remove_windows(space, &ids, ids.count)
        // Windows concealed exclusively have no ordinary Space; one exclusive add moves them
        // back and out of the holding Space.
        ids = move
        if !ids.isEmpty {
            guard let destination = Displays.current().mainCurrentSpace else { return false }
            kosmos_add_windows(destination, &ids, ids.count, true)
        }
        ids = conceal.filter { $0.value == .keepOrdinary }.map(\.key)
        kosmos_add_windows(space, &ids, ids.count, false)
        ids = conceal.filter { $0.value == .exclusive }.map(\.key)
        kosmos_add_windows(space, &ids, ids.count, true)
        guard kosmos_barrier(space), let members = (kosmos_space_windows(space) as? [UInt32]).map(Set.init) else { return false }
        return expectShown.allSatisfy { !members.contains($0) } && expectHidden.allSatisfy { members.contains($0) }
    }

    /// Records the holding Space before any window enters it, and each window before its
    /// first hide. A change is kept only once it is published.
    private func prepare(_ windows: [UInt32]) -> Bool {
        if state == nil {
            guard let windowServer = ProcessIdentity.windowServer() else { return false }
            // Spaces an incomplete recovery left on file stay recorded.
            if let onFile = record.read(), onFile.windowServer == windowServer {
                state = onFile
                state!.manager = .current
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

    /// Runs recovery and returns the windows still concealed afterwards.
    func recover() -> Set<UInt32> {
        _ = recoverOutcome()
        guard let left = record.read() else { return [] }
        return Set(left.spaces.flatMap { kosmos_space_windows($0) as? [UInt32] ?? [] })
    }

    func recoverOutcome() -> Recovery.Outcome {
        let outcome = Recovery.run(file: record)
        hidingLog.notice("recovery: \(String(describing: outcome), privacy: .public)")
        // Start over from the file: empty after a full recovery, the leftovers otherwise.
        state = nil
        space = 0
        return outcome
    }
}
