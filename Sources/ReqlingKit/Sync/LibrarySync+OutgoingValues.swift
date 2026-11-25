import Foundation

/// Global and current values on their way out: only the own coordinator sends them, and current values are compared
/// on their own, since scripts change them on every run.
extension LibrarySync {
    func reconcileLibrary(editedAt: Date? = nil, valuesEditedAt: Date? = nil) {
        guard let store, !store.state.libraryDetached, !store.state.libraryDeferred, let records = localRecords(in: .library) else {
            return
        }
        queueDifferences(records, in: .library, deletingMissing: false, at: editedAt ?? now())
        reconcileCurrentValues(editedAt: valuesEditedAt)
    }

    /// Only current-values records, since scripts change them on every run.
    func reconcileCurrentValues(editedAt: Date? = nil) {
        guard let store else {
            return
        }
        guard role == .own else {
            return
        }
        var zones: [SyncZone] = store.state.libraryDetached || store.state.libraryDeferred ? [] : [.library]
        // Every project's, shared ones' included: this person's values are theirs, in their own database.
        zones += library.projects.filter { syncsValues(of: $0) && isReadFully($0) }.map { .personal($0.id) }
        for zone in zones {
            let records = currentValuesRecords(in: zone)
            if case .personal = zone, !records.isEmpty, !store.hasBases(in: zone) {
                transport.enqueue([.saveZone(zone)])
            }
            queueDifferences(records, in: zone, deletingMissing: false, at: editedAt ?? now())
            var deletions: [SyncPendingChange] = []
            for id in store.baseIDs(in: zone) where id.name.hasPrefix(SyncRecordID.currentValuesPrefix) && records[id] == nil {
                guard let scope = LibraryRecordCoder.scope(of: id), isLiveScope(scope) else {
                    continue
                }
                store.notePending(id, fingerprint: nil, at: editedAt ?? now())
                deletions.append(.delete(id))
            }
            transport.enqueue(deletions)
        }
    }

    /// Whether `scope`'s environment still exists here, so its values going is a reset rather than a deletion.
    func isLiveScope(_ scope: CurrentValueScope) -> Bool {
        switch scope {
        case .global: true
        case .environment(let project, let environment): library.document(project)?.environment(environment) != nil
        }
    }
}
