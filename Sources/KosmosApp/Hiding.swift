import CKosmos
import Foundation
import KosmosRecovery
import KosmosSkyLight
import os

private let hidingLog = Logger(subsystem: "io.github.st-eez.kosmos", category: "hiding")

/// Conceals windows of hidden workspaces in one holding Space (DESIGN.md, sections 4.3 and
/// 5.3). The Space and each window are recorded before they are first used, so recovery
/// can always find them.
@MainActor
final class Hiding {
    /// How a window leaves the screen. An app's selected window keeps its ordinary Space
    /// membership so Command-Tab still picks it; the app's other concealed windows lose it.
    enum Conceal { case keepOrdinary, exclusive }

    private let record: RecordFile
    private let guardian: Guardian
    private let bridge = DispatchQueue(label: "kosmos.bridge", qos: .userInteractive)
    private var state: RecoveryRecord?
    private var space: UInt64 = 0
    /// How each concealed window was concealed.
    private var concealed: [UInt32: Conceal] = [:]

    init(record: RecordFile, guardian: Guardian) {
        self.record = record
        self.guardian = guardian
    }

    var isAvailable: Bool { guardian.isReady }

    func isConcealed(_ window: UInt32) -> Bool { concealed[window] != nil }

    /// Reveals `show`, then conceals `hide`, then reads the barrier, all on the bridge
    /// queue. `done` gets true when a membership check confirms the whole batch. On
    /// failure every concealed window is restored and the batch must be retried.
    func apply(show: [UInt32], hide: [UInt32: Conceal], done: @escaping @MainActor (Bool) -> Void) {
        guard guardian.isReady else { return done(false) }
        guard prepare(hide.keys) else { return done(false) }
        let space = self.space
        let reveal = show.filter { concealed[$0] == .keepOrdinary }
        let move = show.filter { concealed[$0] == .exclusive }
        let keep = hide.filter { $0.value == .keepOrdinary }.map(\.key)
        let strip = hide.filter { $0.value == .exclusive }.map(\.key)
        let destination = Displays.current().mainCurrentSpace ?? 0
        for id in show { concealed[id] = nil }
        concealed.merge(hide) { _, new in new }

        bridge.async {
            var ids = reveal
            kosmos_remove_windows(space, &ids, ids.count)
            // Windows concealed exclusively have no ordinary Space to fall back to.
            ids = move
            if destination != 0 { kosmos_add_windows(destination, &ids, ids.count, true) }
            ids = keep
            kosmos_add_windows(space, &ids, ids.count, false)
            ids = strip
            kosmos_add_windows(space, &ids, ids.count, true)
            let confirmed = kosmos_barrier(space) && Self.members(of: space).map { members in
                show.allSatisfy { !members.contains($0) } && hide.keys.allSatisfy { members.contains($0) }
            } == true
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if !confirmed { self.fail() }
                    done(confirmed)
                }
            }
        }
    }

    /// Creates the holding Space on first use and records it and any window about to be
    /// concealed for the first time.
    private func prepare(_ windows: some Collection<UInt32>) -> Bool {
        if state == nil {
            guard let windowServer = ProcessIdentity.windowServer() else { return false }
            state = RecoveryRecord(windowServer: windowServer, manager: .current)
        }
        if space == 0 {
            let created = kosmos_holding_create()
            guard created != 0 else {
                hidingLog.error("holding Space not created")
                return false
            }
            // Recorded before any window enters it.
            state!.spaces.append(created)
            guard record.publish(state!) else { return false }
            space = created
        }
        let known = Set(state!.windows.map(\.id))
        let new = windows.filter { !known.contains($0) }
        guard !new.isEmpty else { return true }
        let rows = Dictionary(uniqueKeysWithValues: SkyLight.rows(Array(new)).map { ($0.id, $0) })
        for id in new {
            guard let row = rows[id], let owner = ProcessIdentity.of(row.pid) else { return false }
            let original = (kosmos_window_spaces(id) as? [UInt64])?.first ?? 0
            state!.windows.append(.init(id: id, owner: owner, originalSpace: original))
        }
        if record.publish(state!) { return true }
        // The slot is full: drop records of windows that no longer exist.
        let alive = Set(SkyLight.rows(state!.windows.map(\.id)).map(\.id))
        state!.windows.removeAll { !alive.contains($0.id) }
        return record.publish(state!)
    }

    /// Restores every concealed window and forgets the Space; the next switch starts over.
    private func fail() {
        hidingLog.error("a bridged operation was not confirmed; restoring every concealed window")
        let outcome = Recovery.run(file: record)
        hidingLog.notice("recovery: \(String(describing: outcome), privacy: .public)")
        concealed = [:]
        space = 0
        state = nil
    }

    nonisolated private static func members(of space: UInt64) -> Set<UInt32>? {
        (kosmos_space_windows(space) as? [UInt32]).map(Set.init)
    }
}
