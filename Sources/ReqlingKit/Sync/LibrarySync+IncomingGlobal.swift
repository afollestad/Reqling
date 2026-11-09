import Foundation
import ReqlingTemplating

/// Other Macs' changes to Global, current values, and tombstones on their way in.
extension LibrarySync {
    func applyLibrary(_ fetched: SyncFetchedZone) {
        guard let store else {
            return
        }
        let changed = fetched.changed.filter { isAcceptable($0, in: .library) }
        applyTombstones(changed, deleted: fetched.deleted)
        guard !store.state.libraryDetached, !store.state.libraryDeferred else {
            return
        }
        let incoming = changed.filter { $0.type != .projectTombstone }
        if incoming.contains(where: isTooNew) {
            deferLibrary(untilUpdate: true)
            return
        }
        let held = (localRecords(in: .library) ?? [:]).merging(currentValuesRecords(in: .library)) { first, _ in first }
        var merged: [SyncRecordID: SyncRecord] = [:]
        var resend: [SyncPendingChange] = []
        for record in incoming {
            let base = store.base(record.id)
            // One carrying secret values this Mac lacks isn't an echo, so the merge fills them in.
            guard differs(record, from: base) || withheld.contains(record.id) else {
                store.setBase(from: record)
                continue
            }
            let result = held[record.id].map { merge($0, with: record, base: base) } ?? record
            guard applyLibraryRecord(result) else {
                continue
            }
            store.setBase(from: record)
            merged[record.id] = result
            if result.payload != record.payload || result.secrets != record.secrets {
                resend.append(.save(record.id))
            } else {
                store.clearPending(record.id)
            }
        }
        for id in fetched.deleted where LibraryRecordCoder.tombstonedProject(id) == nil {
            if let kept = resetElsewhere(id, local: held[id]) {
                merged[id] = kept
                resend.append(.save(id))
            }
        }
        encoded[.library] = nil
        queue(resend, from: merged)
    }

    /// Tombstones say what other Macs deleted, whatever else is held back here. One this Mac saved coming back isn't
    /// another Mac's, and one whose deletion is queued here was withdrawn, by adding its project back.
    private func applyTombstones(_ changed: [SyncRecord], deleted: [SyncRecordID]) {
        guard let store else {
            return
        }
        let fresh = changed.filter { $0.type == .projectTombstone && differs($0, from: store.base($0.id)) }
        for record in fresh where store.pending(record.id)?.isDeletion != true {
            if let project = LibraryRecordCoder.tombstonedProject(record.id) {
                store.update { $0.tombstones.insert(project) }
            }
            store.setBase(from: record)
        }
        for id in deleted {
            if let project = LibraryRecordCoder.tombstonedProject(id) {
                // Added back on another Mac, so its zone vanishing again wouldn't be that deletion.
                store.update { $0.tombstones.remove(project) }
                store.removeBase(id)
            }
        }
    }

    /// A Global record deleted elsewhere: this Mac's copy when an edit here since it last synced, or one never synced,
    /// beats the reset; otherwise `nil`, and Global's current values reset here too. Global's own record goes only with a
    /// reset, and this Mac's copy goes up again with the next reconcile.
    private func resetElsewhere(_ id: SyncRecordID, local: SyncRecord?) -> SyncRecord? {
        guard let store else {
            return nil
        }
        let isKept = local.map(isEditedHere) ?? false
        store.removeBase(id)
        if isKept, let local {
            return local
        }
        if case .global? = LibraryRecordCoder.scope(of: id) {
            library.currentValues.applySynced([:], secrets: [:], in: .global)
            store.clearPending(id)
        }
        return nil
    }

    /// Writes one merged Global or Global current-values record. `false` when it couldn't be.
    private func applyLibraryRecord(_ record: SyncRecord) -> Bool {
        do {
            switch record.type {
            case .globalEnvironment:
                let global = try LibraryRecordCoder.global(from: record, local: library.globalEnvironment)
                try library.applySyncedGlobalEnvironment(global.variables, storingSecrets: global.secrets)
            case .currentValues:
                let decoded = try LibraryRecordCoder.currentValues(from: record)
                let (values, secrets) = secured(decoded.values, decoded.secrets, in: .global, document: nil)
                library.currentValues.applySynced(values, secrets: secrets, in: .global)
            case .project, .folder, .request, .environment, .projectTombstone:
                return false
            }
            return true
        } catch is SyncRecordError {
            deferLibrary(untilUpdate: false)
            return false
        } catch {
            refetchAfterFailure()
            report("Global's changes from another Mac couldn't be saved here: \(error.localizedDescription)")
            return false
        }
    }

    private func deferLibrary(untilUpdate: Bool) {
        store?.update { state in
            Self.noteDeferral(untilUpdate: untilUpdate, in: &state)
            state.libraryDeferred = true
        }
    }

    /// Writes each changed scope's current values, forcing secret any value this Mac knows to be one, and empties each
    /// scope deleted on both Macs.
    func applyCurrentValues(_ records: [SyncRecord], cleared: Set<SyncRecordID>, in document: ProjectDocument) {
        for record in records {
            guard let scope = LibraryRecordCoder.scope(of: record.id), let decoded = try? LibraryRecordCoder.currentValues(from: record) else {
                continue
            }
            if case .environment(_, let environment) = scope, document.environment(environment) == nil {
                continue
            }
            let (values, secrets) = secured(decoded.values, decoded.secrets, in: scope, document: document)
            library.currentValues.applySynced(values, secrets: secrets, in: scope)
        }
        for id in cleared {
            if let scope = LibraryRecordCoder.scope(of: id) {
                library.currentValues.applySynced([:], secrets: [:], in: scope)
            }
        }
    }

    /// A plain value under a key this Mac holds as secret, or holding one of its secrets, becomes secret here.
    func secured(
        _ values: [String: StoredCurrentValue],
        _ secrets: [String: String],
        in scope: CurrentValueScope,
        document: ProjectDocument?
    ) -> ([String: StoredCurrentValue], [String: String]) {
        var environments = [library.globalEnvironment]
        if case .environment(_, let id) = scope, let environment = document?.environment(id) {
            environments.append(environment)
        }
        let secretVariables = environments.flatMap(\.variables).filter(\.isSecret)
        let secretKeys = Set(secretVariables.map(\.key))
        let secretValues = Set(secretVariables.map(\.value)).union(secrets.values)
        var values = values
        var secrets = secrets
        for (key, value) in values {
            if case .plain(let text) = value, secretKeys.contains(key) || VariableLayers.contains(text, anyOf: secretValues) {
                values[key] = .secret
                secrets[key] = text
            }
        }
        return (values, secrets)
    }
}
