import CryptoKit
import Foundation
import Observation

/// Where iCloud sync stands, for Settings.
public enum SyncStatus: Equatable, Sendable {
    /// This build has no iCloud entitlement (ad hoc builds, tests).
    case unavailable
    case off
    case signedOut
    case syncing
    case upToDate(Date)
    /// Paused: a different iCloud account is signed in than this Mac's projects last synced with.
    case accountChanged
    /// Paused: another Mac deleted several projects at once, and these wait for a confirmation.
    case confirmingDeletions([ProjectID])
    /// Turned off because Reqling's iCloud data was deleted or reset; turning sync on again uploads this Mac's copy.
    case stopped(SyncStopReason)
    case failed(String)
}

public enum SyncStopReason: Equatable, Sendable {
    /// Deleted in System Settings.
    case dataDeleted
    /// The account's end-to-end encrypted data was reset.
    case encryptionReset
}

/// Syncs the projects in Reqling's own folder, Global, and current values through the transport (`CloudKitSyncTransport`
/// in the app), keeping each project folder the source of truth on each Mac.
///
/// Outgoing, every change this Mac makes (`ProjectLibrary.changeObserver`) is compared, record by record, against
/// what was last synced (`SyncBaseStore`), and what differs is queued; records are built only as they're sent.
/// Incoming, a zone is applied once its fetch completes, merged field by field (`SyncJSONMerge`) with any edit here
/// that isn't sent yet, and written through the library's sync entry points, which never report it back.
@MainActor
@Observable
public final class LibrarySync {
    public internal(set) var status: SyncStatus = .off
    /// What went wrong with particular items, in words for Settings.
    public internal(set) var issues: [String] = []

    @ObservationIgnored let library: ProjectLibrary
    @ObservationIgnored let lifecycle: ProjectLifecycle
    @ObservationIgnored let secretStore: any SecretStore
    @ObservationIgnored let transport: any SyncTransport
    @ObservationIgnored let directory: URL
    @ObservationIgnored let now: () -> Date
    @ObservationIgnored var store: SyncBaseStore?
    /// Called when sync turns itself off (its iCloud data was deleted or reset), so the setting can follow.
    @ObservationIgnored public var onStop: ((SyncStopReason) -> Void)?

    /// Each zone's records as this Mac holds them, built once per change rather than once per record sent.
    @ObservationIgnored var encoded: [SyncZone: [SyncRecordID: SyncRecord]] = [:]
    /// Whether Reqling is frontmost. Fetched changes wait until it is, so applying one never shows a Keychain dialog in
    /// the background or writes while no one is looking.
    @ObservationIgnored var isActive = true
    @ObservationIgnored var heldZones: [SyncFetchedZone] = []
    @ObservationIgnored var heldZoneDeletions: [(SyncZone, SyncZoneDeletionReason)] = []
    @ObservationIgnored var heldFinish = false
    /// The transport's state from the latest fetch, saved once what it covers is applied.
    @ObservationIgnored var unsavedTransportState: Data?
    /// Requests each project lost and gained in one fetch, so a move between projects carries its history.
    @ObservationIgnored var removedRequests: [ProjectID: Set<RequestNodeID>] = [:]
    @ObservationIgnored var addedRequests: [ProjectID: Set<RequestNodeID>] = [:]
    @ObservationIgnored var awaitingConfirmation: [ProjectID] = []

    init(
        library: ProjectLibrary,
        lifecycle: ProjectLifecycle,
        secretStore: any SecretStore,
        directory: URL,
        transport: any SyncTransport,
        now: @escaping () -> Date = Date.init
    ) {
        self.library = library
        self.lifecycle = lifecycle
        self.secretStore = secretStore
        self.directory = directory
        self.transport = transport
        self.now = now
    }

    var projectsDirectory: URL {
        library.configuration.defaultProjectsDirectory
    }

    // MARK: - Starting and stopping

    /// Signs in to the transport's account and syncs everything in scope.
    public func start() async {
        library.changeObserver = { [weak self] change in
            self?.libraryChanged(change)
        }
        transport.delegate = self
        await connect()
    }

    /// Stops listening, keeping both copies of everything.
    public func stop() {
        library.changeObserver = nil
        store?.save()
        store = nil
        status = .off
    }

    /// Opens the signed-in account's state, or pauses when the account isn't the one this Mac last synced with. Accepting
    /// a new account merges into it only the projects in `merging`; the rest stay on this Mac, out of sync.
    func connect(acceptingNewAccount merging: Set<ProjectID>? = nil) async {
        guard let account = try? await transport.accountID() else {
            store = nil
            status = .signedOut
            return
        }
        guard let key = loadKey() else {
            status = .failed("Reqling couldn't use its iCloud key in the Keychain.")
            return
        }
        let folder = SyncBaseStore.folderName(for: account)
        if let last = lastAccountFolder(), last != folder, merging == nil {
            store = nil
            status = .accountChanged
            return
        }
        rememberAccountFolder(folder)
        let store = SyncBaseStore(directory: directory, account: account, key: key)
        self.store = store
        status = .syncing
        if let merging {
            // Detached rather than excluded, which an edit would undo: these stay on this Mac until removed and added again.
            for project in library.projects where isInScope(project) && !merging.contains(project.id) {
                store.update { $0.detached.insert(project.id) }
            }
        }
        transport.start(with: store.state.transportState)
        // A refetch retries what couldn't be applied, and a project held back for a newer version is judged again.
        if store.state.needsRefetch || !store.state.deferred.isEmpty {
            transport.resetState()
            store.update { state in
                state.needsRefetch = false
                state.deferred = []
            }
        }
        forgetSetAsideScopes()
        relistUnlistedProjects()
        reconcileEverything()
        await syncNow()
    }

    /// Fetches what changed, then sends what's queued, including anything the fetch merged. Fetching first matters for
    /// deletions, which the server applies whatever version it holds: an edit another Mac made to a record deleted here
    /// arrives, and beats the deletion, before the deletion goes out.
    public func syncNow() async {
        guard store != nil, canSync else {
            return
        }
        status = .syncing
        await transport.fetchChanges()
        await transport.sendChanges()
        store?.save()
        if case .syncing = status {
            status = .upToDate(now())
        }
    }

    /// Adds `issue` for Settings once, however often it recurs.
    func report(_ issue: String) {
        if !issues.contains(issue) {
            issues.append(issue)
        }
    }

    /// Writes what sync keeps on this Mac; Reqling calls it as it quits.
    public func flush() {
        store?.save()
    }

    var canSync: Bool {
        switch status {
        case .accountChanged, .confirmingDeletions, .stopped, .unavailable, .signedOut:
            false
        case .off, .syncing, .upToDate, .failed:
            true
        }
    }

    /// Reqling came to the front or left it. Coming forward applies what was fetched meanwhile and fetches again, since
    /// macOS delivers CloudKit's changes lazily to an app in the background.
    public func setActive(_ active: Bool) async {
        isActive = active
        guard active, store != nil else {
            return
        }
        applyHeldChanges()
        await syncNow()
    }

    /// Projects held back because another Mac with a newer Reqling changed them; their edits here wait to sync.
    public var deferredProjects: Set<ProjectID> {
        store?.state.deferred ?? []
    }

    /// A Global or current-values file that couldn't be read loaded empty, which mustn't read as everything deleted:
    /// dropping its bases makes the next merge a union, so the server's copy comes back.
    private func forgetSetAsideScopes() {
        guard let store else {
            return
        }
        if library.globalEnvironmentWasSetAside {
            store.removeBase(LibraryRecordCoder.globalRecordID)
        }
        if library.currentValues.wasSetAside {
            store.update { state in
                state.bases = state.bases.filter { !$0.key.contains("/" + SyncRecordID.currentValuesPrefix) }
            }
        }
    }

    /// Lists again each synced project whose folder is still in Reqling's folder but fell off the library's list, as when
    /// the list was set aside, so it isn't fetched as a new project beside its own folder.
    private func relistUnlistedProjects() {
        guard let store else {
            return
        }
        let zones = Set(store.state.bases.keys.compactMap { $0.split(separator: "/").first.flatMap { SyncZone(name: String($0)) } })
        for case .project(let id) in zones where library.project(id) == nil && !store.state.excluded.contains(id) {
            if let folder = library.unlistedFolder(with: id, in: projectsDirectory) {
                _ = try? lifecycle.addProjectFolder(folder)
            }
        }
    }

    // MARK: - Choices the person makes

    /// After another account signed in: syncs the projects in `merging` into it and keeps the rest on this Mac only,
    /// out of sync, so one account's data never reaches another's unasked. Global and current values go along only when
    /// `merging` isn't empty.
    public func resolveAccountChange(merging: Set<ProjectID>) async {
        guard status == .accountChanged else {
            return
        }
        await connect(acceptingNewAccount: merging)
    }

    /// Moves the projects another Mac deleted to the Trash, or, declined, keeps them here and stops syncing them.
    public func confirmDeletions(_ confirmed: Bool) async {
        guard case .confirmingDeletions = status, let store else {
            return
        }
        for project in awaitingConfirmation {
            if confirmed {
                deleteRemotelyDeleted(project)
            } else {
                store.forget(.project(project))
                store.update { $0.detached.insert(project) }
            }
        }
        awaitingConfirmation = []
        store.save()
        status = .upToDate(now())
    }

    // MARK: - Keys and accounts

    /// The digest key, created on first use, kept in its own Keychain item (`SecretAccount.sync`).
    private func loadKey() -> SymmetricKey? {
        guard let stored = try? secretStore.secrets(for: .sync) else {
            return nil
        }
        if let text = stored["key"], let data = Data(base64Encoded: text) {
            return SymmetricKey(data: data)
        }
        let key = SyncDigester.makeKey()
        let data = key.withUnsafeBytes { Data($0) }
        guard (try? secretStore.update(.sync, storing: ["key": data.base64EncodedString()], deleting: [])) != nil else {
            return nil
        }
        return key
    }

    private var accountMarker: URL {
        directory.appendingPathComponent("account")
    }

    private func lastAccountFolder() -> String? {
        (try? String(contentsOf: accountMarker, encoding: .utf8)).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private func rememberAccountFolder(_ folder: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? Data(folder.utf8).write(to: accountMarker, options: .atomic)
    }

    /// Turns sync off after the account's data for Reqling was deleted or reset: the SDK requires dropping what was
    /// cached and never sending it back on its own. Project folders are the person's files, so they stay.
    func stopAfterServerReset(_ reason: SyncStopReason) {
        store?.reset()
        store = nil
        transport.resetState()
        library.changeObserver = nil
        status = .stopped(reason)
        onStop?(reason)
    }
}
