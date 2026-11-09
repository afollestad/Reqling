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

    /// Each zone's project, folder, request, environment, or Global records as this Mac holds them, built once per change
    /// rather than once per record sent. Current values are built fresh, since scripts change them on every run.
    @ObservationIgnored var encoded: [SyncZone: [SyncRecordID: SyncRecord]] = [:]
    /// Whether Reqling is frontmost. Fetched changes wait until it is, so applying one never shows a Keychain dialog in
    /// the background or writes while no one is looking, and nothing is sent while they wait.
    @ObservationIgnored var isActive = true
    /// What fetches delivered in the background, in order, replayed on coming forward (`applyHeldChanges`), so each
    /// fetch is judged with only its own zones applied before it.
    @ObservationIgnored var heldEvents: [HeldFetchEvent] = []
    /// The zone deletions of the fetch being applied, judged together once it finishes (`finish(wholeDelivery:)`).
    @ObservationIgnored var heldZoneDeletions: [(SyncZone, SyncZoneDeletionReason)] = []
    /// The zones the fetch under way has delivered, so a whole one can tell which zones are gone.
    @ObservationIgnored var deliveredZones: Set<SyncZone> = []
    /// Whether a refetch was asked for since the current fetch began, so finishing a whole one keeps the request.
    @ObservationIgnored var refetchRaised = false
    /// Whether a whole fetch left something to fetch again, which another won't fix before a relaunch or Sync Now.
    @ObservationIgnored var wholeFetchFellShort = false
    /// The edit time each record went out with, as this Mac's clock read it, to tell whether a save covers the edit.
    @ObservationIgnored var sentEdits: [SyncRecordID: Date] = [:]
    /// When the last fetch finished, which a deletion must postdate before it goes out (`shouldSend`).
    @ObservationIgnored var lastFetchFinished: Date = .distantPast
    /// The transport's state from the latest fetch or send, saved once what it covers is applied.
    @ObservationIgnored var unsavedTransportState: Data?
    /// Requests each project lost and gained in one fetch, so a move between projects carries its history.
    @ObservationIgnored var removedRequests: [ProjectID: Set<RequestNodeID>] = [:]
    @ObservationIgnored var addedRequests: [ProjectID: Set<RequestNodeID>] = [:]
    /// Records whose secrets stay unsent because this Mac lacks a value the server holds (`noteWithheld`).
    @ObservationIgnored var withheld: Set<SyncRecordID> = []
    /// Whether `start` ran with no `stop` or server reset since; nothing reconnects or syncs otherwise.
    @ObservationIgnored var isRunning = false
    /// Counts connections, so one that a stop or another connection replaced while it awaited gives up.
    @ObservationIgnored var connection = 0
    /// Whether reading the account failed, rather than finding none signed in, so coming forward or Sync Now tries again.
    @ObservationIgnored var needsReconnect = false

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

    /// `SyncBaseStore.State.clockSkew`.
    var clockSkew: TimeInterval {
        store?.state.clockSkew ?? 0
    }

    /// Asks for everything to be fetched again as soon as a sync can (`syncNow`), for a new reason, as when a project
    /// comes back, which a whole fetch that fell short before mustn't hold up.
    func requestRefetch() {
        refetchAfterFailure()
        wholeFetchFellShort = false
    }

    /// Asks for a refetch because something fetched couldn't be applied; repeated failures wait for Sync Now.
    func refetchAfterFailure() {
        store?.update { $0.needsRefetch = true }
        refetchRaised = true
    }

    // MARK: - Starting and stopping

    /// Signs in to the transport's account and syncs everything in scope.
    public func start() async {
        isRunning = true
        library.changeObserver = { [weak self] change in
            self?.libraryChanged(change)
        }
        transport.delegate = self
        await connect()
    }

    /// Stops listening, keeping both copies of everything.
    public func stop() {
        halt()
        status = .off
    }

    /// Stops listening to the library and the transport, and ends any connection still awaiting.
    private func halt() {
        isRunning = false
        connection += 1
        library.changeObserver = nil
        transport.delegate = nil
        store?.save()
        store = nil
    }

    /// Opens the signed-in account's state, or pauses when the account isn't the one this Mac last synced with. Accepting
    /// a new account merges into it only the projects in `merging`, and Global with them unless `merging` is empty; the
    /// rest stay on this Mac, out of sync.
    func connect(acceptingNewAccount merging: Set<ProjectID>? = nil) async {
        guard isRunning else {
            return
        }
        connection += 1
        let attempt = connection
        dropConnection()
        let account: String?
        do {
            account = try await transport.accountID()
        } catch {
            if attempt == connection {
                needsReconnect = true
                status = .failed("Reqling couldn't reach iCloud. It tries again when it comes to the front.")
            }
            return
        }
        guard attempt == connection else {
            return
        }
        guard let account else {
            status = .signedOut
            return
        }
        guard let key = loadKey() else {
            needsReconnect = true
            status = .failed("Reqling couldn't use its iCloud key in the Keychain. It tries again when it comes to the front.")
            return
        }
        let folder = SyncBaseStore.folderName(for: account)
        if let last = lastAccountFolder(), last != folder, merging == nil {
            status = .accountChanged
            return
        }
        rememberAccountFolder(folder)
        let store = SyncBaseStore(directory: directory, account: account, key: key)
        self.store = store
        status = .syncing
        if let merging {
            keepOutOfNewAccount(allBut: merging)
        }
        transport.start(with: store.state.transportState)
        resume(store)
        if !store.state.awaitingConfirmation.isEmpty {
            status = .confirmingDeletions(store.state.awaitingConfirmation)
            return
        }
        await syncNow()
    }

    /// Forgets the connection in use, so nothing of a previous account's applies to the next, even should it fail.
    private func dropConnection() {
        store?.save()
        store = nil
        heldEvents = []
        heldZoneDeletions = []
        deliveredZones = []
        refetchRaised = false
        wholeFetchFellShort = false
        sentEdits = [:]
        unsavedTransportState = nil
        lastFetchFinished = .distantPast
        withheld = []
        needsReconnect = false
    }

    /// Picks up where `store` left off: what a newer version wrote is judged again once this one is newer than when it
    /// was held back, deletions made here outlive the queue they were in, and everything changed meanwhile is queued.
    private func resume(_ store: SyncBaseStore) {
        let isDeferring = !store.state.deferred.isEmpty || store.state.libraryDeferred
        if isDeferring, store.state.deferredAt != SyncBaseStore.versions {
            store.update { state in
                state.deferred = []
                state.libraryDeferred = false
            }
            requestRefetch()
        }
        transport.enqueue(store.state.outgoingTombstones.map { .save(LibraryRecordCoder.tombstoneRecordID($0)) })
        transport.enqueue(store.state.outgoingZoneDeletions.map { .deleteZone(.project($0)) })
        forgetSetAsideScopes()
        reconcileListedProjects()
        reconcileEverything(stampingFromFiles: true)
    }

    /// Fetches what changed, then sends what's queued, including anything the fetch merged. Fetching first matters for
    /// deletions, which the server applies whatever version it holds: an edit another Mac made to a record deleted here
    /// arrives, and beats the deletion, before the deletion goes out. In the background it only fetches, since what it
    /// fetched waits for Reqling to come forward.
    ///
    /// What couldn't be applied (`State.needsRefetch`) is fetched whole first, and once more in front should this fetch
    /// leave something, such as a project only part of whose records arrived. A whole fetch that still falls short isn't
    /// repeated on every activation: `retryingFailures`, as Sync Now does, or a relaunch tries again.
    public func syncNow(retryingFailures: Bool = false) async {
        guard let store else {
            if needsReconnect {
                await connect()
            }
            return
        }
        guard canSync else {
            return
        }
        if retryingFailures {
            wholeFetchFellShort = false
        }
        let attempt = connection
        status = .syncing
        guard await fetch(into: store, attempt: attempt) else {
            return
        }
        if isActive {
            await transport.sendChanges()
            guard attempt == connection else {
                return
            }
        }
        store.save()
        if case .syncing = status {
            status = isActive && store.state.needsRefetch
                ? .failed("Some changes from another Mac couldn't be applied yet. Sync Now tries again.")
                : .upToDate(now())
        }
    }

    /// Fetches, refetching whole first when asked, and once more in front should this fetch ask again. `false` when a
    /// stop or another connection replaced `attempt` meanwhile.
    private func fetch(into store: SyncBaseStore, attempt: Int) async -> Bool {
        for _ in 0..<2 {
            if store.state.needsRefetch, !wholeFetchFellShort {
                transport.resetState()
            }
            refetchRaised = false
            await transport.fetchChanges()
            guard attempt == connection else {
                return false
            }
            guard isActive, store.state.needsRefetch, !wholeFetchFellShort else {
                break
            }
        }
        return true
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

    /// Reqling came to the front or left it. Coming forward applies what was fetched meanwhile and syncs, since macOS
    /// delivers CloudKit's changes lazily to an app in the background.
    public func setActive(_ active: Bool) async {
        isActive = active
        guard active, isRunning else {
            return
        }
        if store != nil {
            applyHeldChanges()
        }
        await syncNow()
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
        halt()
        status = .stopped(reason)
        onStop?(reason)
    }
}

/// One thing a fetch delivered while Reqling was in the background.
enum HeldFetchEvent {
    case zone(SyncFetchedZone)
    case zoneDeletion(SyncZone, SyncZoneDeletionReason)
    /// A fetch finished, when it did, with the zones it delivered when it was whole.
    case finish(wholeDelivery: Set<SyncZone>?, finishedAt: Date)
}
