import Foundation

/// What the person chooses about sync, and the choices a connection makes for them: which account's data merges,
/// whether Global syncs, whether deletions from another Mac go to the Trash, and what to do with files set aside.
extension LibrarySync {
    /// Projects held back because another Mac with a newer Reqling changed them; their edits here wait to sync.
    public var deferredProjects: Set<ProjectID> {
        store?.state.deferred ?? []
    }

    /// Whether Global and its current values stay out of this account, as chosen when it signed in.
    public var isGlobalDetached: Bool {
        store?.state.libraryDetached ?? false
    }

    /// Syncs Global and its current values with this account after all, merging both copies as when neither had synced.
    public func attachGlobal() async {
        guard let store, store.state.libraryDetached else {
            return
        }
        // Without bases, the merge keeps what either copy has rather than reading one's absence as a deletion. Tombstones
        // aren't Global's, and a withdrawn one's pending deletion must stay.
        store.update { state in
            let library = SyncZone.library.name + "/"
            let isGlobal = { (key: String) in key.hasPrefix(library) && !key.hasPrefix(library + SyncRecordID.tombstonePrefix) }
            state.bases = state.bases.filter { !isGlobal($0.key) }
            state.pending = state.pending.filter { !isGlobal($0.key) }
            state.libraryDetached = false
        }
        requestRefetch()
        reconcileLibrary()
        await syncNow()
    }

    /// After another account signed in: syncs the projects in `merging` into it and keeps the rest on this Mac only,
    /// out of sync, so one account's data never reaches another's unasked. Global and current values go along only when
    /// `merging` isn't empty.
    public func resolveAccountChange(merging: Set<ProjectID>) async {
        guard status == .accountChanged else {
            return
        }
        await connect(acceptingNewAccount: merging)
    }

    /// Moves the projects another Mac deleted to the Trash, or, declined, keeps them here and stops syncing them. Edits
    /// made while the question was open were noted as they were made, and go out now.
    public func confirmDeletions(_ confirmed: Bool) async {
        guard case .confirmingDeletions = status, let store else {
            return
        }
        for project in store.state.awaitingConfirmation {
            if confirmed {
                deleteRemotelyDeleted(project)
            } else {
                store.forget(.project(project))
                transport.cancelPending(in: .project(project))
                store.update { $0.detached.insert(project) }
            }
        }
        store.update { $0.awaitingConfirmation = [] }
        store.save()
        status = .syncing
        await syncNow()
    }

    /// Detaches every project in scope but `merging`, and Global when that's empty: detached rather than excluded, which
    /// an edit would undo, so they stay on this Mac until removed and added again (or `attachGlobal`).
    func keepOutOfNewAccount(allBut merging: Set<ProjectID>) {
        let kept = library.projects.filter { isInScope($0) && !merging.contains($0.id) }.map(\.id)
        store?.update { state in
            state.detached.formUnion(kept)
            state.detached.subtract(merging)
            state.libraryDetached = merging.isEmpty
        }
    }

    /// A Global or current-values file that couldn't be read loaded empty, which mustn't read as everything deleted:
    /// dropping its bases makes the next merge a union, so the server's copy comes back. Once, not on every reconnect.
    func forgetSetAsideScopes() {
        guard let store else {
            return
        }
        if library.globalEnvironmentWasSetAside {
            store.removeBase(LibraryRecordCoder.globalRecordID)
            library.globalEnvironmentWasSetAside = false
        }
        if library.currentValues.wasSetAside {
            store.update { state in
                state.bases = state.bases.filter { !$0.key.contains("/" + SyncRecordID.currentValuesPrefix) }
            }
            library.currentValues.acknowledgeSetAside()
        }
    }

    /// Squares the synced projects with the library's list. One that fell off it when the list was set aside is listed
    /// again from its folder, so it isn't fetched as a new project beside it, or, with its folder gone too, fetched whole
    /// again rather than rebuilt from whatever changed; one the person removed while sync was off counts as removed, so a
    /// fetch doesn't bring it back.
    func reconcileListedProjects() {
        guard let store else {
            return
        }
        let wasSetAside = library.registryWasSetAside
        library.registryWasSetAside = false
        for case .project(let id) in store.syncedZones where library.project(id) == nil && !store.state.excluded.contains(id) {
            if wasSetAside, let folder = library.unlistedFolder(with: id, in: projectsDirectory), (try? lifecycle.addProjectFolder(folder)) != nil {
                continue
            }
            if wasSetAside {
                store.forget(.project(id))
                requestRefetch()
            } else {
                // Its bases stay, as a removal's do, for adding it back (`readd`).
                store.update { $0.excluded.insert(id) }
            }
        }
    }
}
