import Foundation

/// Projects shared between people. Each person's own sync runs a second coordinator over the shared database
/// (`sharedSync`, role `.shared`) for the projects others share with them, while the own coordinator keeps their own
/// projects, Global, and every project's personal values, theirs or shared, in their private database.
///
/// What a shared coordinator never does, since the zone is its owner's: save, recreate, or delete the zone, upload a
/// project it lacks bases for, send anything of a project shared to view only, or take any of the owner's personal
/// data (`withoutPersonalData`). Losing access, however the share ends, moves the copy here to the Trash; leaving
/// deletes this account's place in the share.
extension LibrarySync {
    /// How this account holds `id`, someone else's project shared with it, or `nil` for its own: as the library lists
    /// it, or, for one not listed yet or gone from the list, as the shared coordinator's share says.
    func sharing(of id: ProjectID) -> ProjectSharing? {
        if let sharing = library.project(id)?.sharing {
            return sharing
        }
        let coordinator = role == .shared ? self : sharedSync
        return coordinator?.store?.state.shares[id]
    }

    /// `id` as the library lists it, with how it's shared restored should it be listed without (`sharingToRestore`).
    func listedProject(_ id: ProjectID) -> LibraryProject? {
        guard var project = library.project(id) else {
            return nil
        }
        if project.sharing == nil, let sharing = sharingToRestore(id) {
            library.setSharing(sharing, for: id)
            project.sharing = sharing
        }
        return project
    }

    /// How `id`, listed without saying so, is shared with this person, as when its folder is added back after Remove
    /// from Reqling, or listed again after a list that couldn't be read: the shared coordinator synced it, and this
    /// person's own database never did. Restored, it never goes up into their own database as theirs.
    private func sharingToRestore(_ id: ProjectID) -> ProjectSharing? {
        guard role == .own, let store, !store.hasBases(in: .project(id)), let sharedSync, sharedSync.holdsCopy(of: id) else {
            return nil
        }
        return sharedSync.store?.state.shares[id]
    }

    /// Whether this shared coordinator synced `id` here: it holds bases for it, or dropped them to take the server's
    /// copy whole (`permissionDenied`).
    func holdsCopy(of id: ProjectID) -> Bool {
        guard let store else {
            return false
        }
        return store.hasBases(in: .project(id)) || store.state.replacing.contains(id)
    }

    /// Whether this coordinator syncs `project`'s own zone: its own projects for the own coordinator, others' for the
    /// shared one.
    func syncsProjectZone(_ project: LibraryProject) -> Bool {
        switch role {
        case .own: project.sharing == nil
        case .shared: project.sharing != nil
        }
    }

    /// What this person can do about sharing `id`, or `nil` for nothing to offer: someone else's project they may not
    /// invite others to, or one that isn't loaded. Only a project that syncs, with none of this person's values left in
    /// its zone by an older Mac, can be shared, since everyone it's shared with reaches the whole zone.
    public func shareAction(for id: ProjectID) -> ProjectShareAction? {
        guard let project = library.project(id), project.document != nil else {
            return nil
        }
        if let sharing = project.sharing {
            return sharing.canInvite ? .manage(readOnlyInvites: sharing.permission == .readOnly) : nil
        }
        guard let store else {
            return .unavailable("Sharing needs iCloud sync, which is off or not connected.")
        }
        guard isInScope(project) else {
            return .unavailable("Only projects in Reqling's own folder sync, so only they can be shared.")
        }
        guard isSyncable(project), store.hasBases(in: .project(id)) else {
            return .unavailable("This project has to sync with iCloud before it can be shared.")
        }
        if holdsLegacyData(id) {
            return .unavailable("Your values in this project are still moving to their own place in iCloud. Share it once it has synced.")
        }
        return store.state.ownedShares[id] == nil ? .share : .manage(readOnlyInvites: false)
    }

    /// Whether `project` is one this account shares with other people.
    public func isShared(_ project: ProjectID) -> Bool {
        sharing(of: project) != nil || store?.state.ownedShares[project]?.audience != nil
    }

    func transport(didUpdateShareOf zone: SyncZone, to share: SyncShareInfo?) {
        guard case .project(let id) = zone, let store else {
            return
        }
        switch role {
        case .shared:
            // A share going arrives as its zone's deletion, judged as lost access (`lostAccess`).
            guard let sharing = share?.sharing else {
                return
            }
            store.update { $0.shares[id] = sharing }
            if library.project(id)?.sharing != nil {
                library.setSharing(sharing, for: id)
            }
        case .own:
            let owned = share.map { OwnedShare(participants: $0.participantCount, byLink: $0.byLink, title: $0.title) }
            store.update { $0.ownedShares[id] = owned }
            sharedByYou[id] = owned?.audience
        }
    }

    /// Keeps each share's title, which invitations show, the project's name: on the owner's Macs, after a rename here or
    /// one fetched from anyone who can edit it. A title that fails to go tries again at the next sync.
    func sendShareTitles() async {
        guard role == .own, let store else {
            return
        }
        for (id, share) in store.state.ownedShares.sorted(by: { $0.key < $1.key }) {
            guard let name = library.project(id)?.name, share.title != name else {
                continue
            }
            guard (try? await transport.setShareTitle(name, of: .project(id))) != nil else {
                continue
            }
            // Another account connected meanwhile: what's left is that one's to title.
            guard self.store === store else {
                return
            }
            store.update { $0.ownedShares[id]?.title = name }
        }
    }

    /// Queues what differs in a project shared with this account. One it holds no bases for is fetched whole rather
    /// than uploaded: the zone is its owner's, so what's here arrived from it. One shared to view only sends nothing.
    func reconcileSharedProject(_ project: LibraryProject, editedAt: Date?) {
        guard let store else {
            return
        }
        let zone = SyncZone.project(project.id)
        guard store.hasBases(in: zone) else {
            requestRefetch()
            return
        }
        guard project.sharing?.permission == .readWrite, let records = localRecords(in: zone) else {
            return
        }
        queueDifferences(records, in: zone, deletingMissing: true, at: editedAt ?? now())
    }

    /// Whether the shared coordinator's copy of `id`, if any, may take its owner's zone: never over a project of this
    /// person's own with its ID, nor one being left, and one not here yet only once its share is known, to say how it's
    /// held.
    func canApplyShared(to id: ProjectID, local: LibraryProject?) -> Bool {
        guard let store, !store.state.leaving.contains(id) else {
            return false
        }
        if let local, local.sharing == nil {
            report("\(name(of: .project(id))) is shared with you, but a project of yours has its ID, so it can't arrive here.")
            return false
        }
        guard store.state.shares[id] != nil else {
            // Its share arrives with a whole fetch.
            requestRefetch()
            return false
        }
        return true
    }

    // MARK: - Connecting

    /// Connects this shared coordinator on the account its owner just read: opened before the owner resumes, so the
    /// owner's resume can tell which listed projects are someone else's (`listedProject`), and resumed only after it
    /// (`resumeOpened`). One that fails to open connects on its own at its next sync.
    func open(account: String?) {
        connection += 1
        dropConnection()
        guard isRunning, let store = openStore(for: account, merging: nil) else {
            return
        }
        transport.start(with: store.state.transportState, account: account)
    }

    func resumeOpened() {
        if let store {
            resume(store)
        }
    }

    // MARK: - Leaving and losing access

    /// Leaves the share of `id`, which this person deleted here: this account's place in it goes, and the project
    /// stays with its owner and everyone else. Kept in the state until done, outliving a quit.
    func leave(_ id: ProjectID) {
        guard let store, store.state.shares[id] != nil else {
            return
        }
        let zone = SyncZone.project(id)
        transport.cancelPending(in: zone)
        store.forget(zone)
        let share = SyncRecordID.share(in: zone)
        store.update { $0.leaving.insert(id) }
        store.notePending(share, fingerprint: nil, at: now())
        store.save()
        transport.enqueue([.delete(share)])
    }

    /// The share of `id` went, as its deletion here says: left, so the copy here went already, or no longer reachable,
    /// as when its owner stopped sharing, removed this account, or deleted the project, so the copy here moves to the
    /// Trash, where Finder can put it back as this person's own.
    func lostAccess(_ id: ProjectID) {
        guard let store else {
            return
        }
        let zone = SyncZone.project(id)
        store.forget(zone)
        transport.cancelPending(in: zone)
        encoded[zone] = nil
        let wasLeaving = store.state.leaving.contains(id)
        store.update { state in
            state.shares[id] = nil
            state.leaving.remove(id)
            state.replacing.remove(id)
        }
        owningSync?.deletePersonalZone(of: id)
        guard !wasLeaving, let project = library.project(id), project.sharing != nil else {
            return
        }
        let name = name(of: zone)
        do {
            try lifecycle.deleteSyncedProject(id)
            report("\(name) is no longer shared with you, so it moved to the Trash.")
        } catch {
            // Kept here as this person's own, no longer syncing, rather than lost.
            library.setSharing(nil, for: id)
            owningSync?.store?.update { $0.detached.insert(id) }
            report("\(name) is no longer shared with you and couldn't be moved to the Trash, so it stays on this Mac.")
        }
    }

    /// A shared zone a whole fetch didn't deliver: reachable no more, but with no word of why, so the copy here stays,
    /// as this person's own, rather than going on an inference (`Sources/ReqlingKit/Sync/AGENTS.md`).
    func lostTrackOf(_ id: ProjectID) {
        guard let store else {
            return
        }
        let zone = SyncZone.project(id)
        store.forget(zone)
        transport.cancelPending(in: zone)
        store.update { $0.shares[id] = nil }
        guard library.project(id)?.sharing != nil else {
            return
        }
        library.setSharing(nil, for: id)
        owningSync?.store?.update { $0.detached.insert(id) }
        report("\(name(of: zone)) can't be reached in iCloud anymore, so it stays on this Mac as yours and no longer syncs.")
    }

    /// Deletes the personal zone of `id`, a shared project this account no longer has, with what it held of this person's.
    func deletePersonalZone(of id: ProjectID) {
        guard let store else {
            return
        }
        let zone = SyncZone.personal(id)
        transport.cancelPending(in: zone)
        guard store.hasBases(in: zone) else {
            return
        }
        store.forget(zone)
        transport.enqueue([.deleteZone(zone)])
    }

    // MARK: - Refusals

    /// The server refused a change to `id` this account's share no longer allows, as when its owner made it read-only:
    /// what it held goes, nothing of it is sent again, and the copy here gives way whole to the server's at the next
    /// whole fetch, rather than merging with edits that can't go out.
    func permissionDenied(_ id: SyncRecordID) {
        guard role == .shared, let store, case .project(let project) = id.zone else {
            reportFailure("iCloud refused a change. Sync Now tries again.")
            return
        }
        sentEdits[id] = nil
        if var sharing = sharing(of: project), sharing.permission == .readWrite {
            sharing.permission = .readOnly
            store.update { $0.shares[project] = sharing }
            library.setSharing(sharing, for: project)
        }
        let zone = SyncZone.project(project)
        transport.cancelPending(in: zone)
        store.forget(zone)
        store.update { $0.replacing.insert(project) }
        requestRefetch()
        report("You can no longer change \(name(of: zone)), so your changes to it are undone.")
    }
}

/// Who one of this account's own projects is shared with.
public struct ShareAudience: Equatable, Sendable {
    /// How many people besides this account take part, invited or joined by the link.
    public var people: Int
    /// Whether anyone with the link may join.
    public var byLink: Bool

    public init(people: Int, byLink: Bool) {
        self.people = people
        self.byLink = byLink
    }
}

/// What this person can do about sharing a project, for its menus.
public enum ProjectShareAction: Equatable, Sendable {
    /// Share…: a project of their own, syncing, and shared with no one yet.
    case share
    /// Manage Sharing…: their own project, shared already, or someone else's they may invite others to; with
    /// `readOnlyInvites`, only to view it, since this person may only view it themselves.
    case manage(readOnlyInvites: Bool)
    /// Share…, unavailable for the reason given.
    case unavailable(String)
}
