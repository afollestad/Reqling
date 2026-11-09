import Foundation
import Observation
import ReqlingKit

/// iCloud sync for the window and Settings ▸ iCloud: started at launch when Settings has it on, told when Reqling comes
/// forward or leaves, synced soon after each change made here, and handed the choices only the person can make.
@MainActor
@Observable
final class ICloudSyncModel {
    /// The Apple Account pane's iCloud section. A macOS that doesn't know the anchor still opens Apple Account, one click
    /// from iCloud.
    static let iCloudSettingsURL = URL(string: "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings?iCloud")
    /// How long sync waits after a change made here, so a burst of edits goes out together.
    static let localChangeDelay: Duration = .seconds(2)
    /// How far ahead Settings warns that this build's provisioning profile expires.
    static let expiryWarningInterval: TimeInterval = 30 * 24 * 60 * 60

    /// Set as an account first syncs on this Mac, for the window to say what syncs; cleared once it has.
    var showsFirstSyncNotice = false
    /// The projects the person ticked or unticked in the account choice, over what each starts as.
    private var mergeOverrides: [ProjectID: Bool] = [:]

    /// `nil` where sync can't run: a test graph, which must never reach iCloud, or a build without the entitlement.
    @ObservationIgnored let sync: LibrarySync?
    @ObservationIgnored private let library: ProjectLibrary
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let system: any SystemIntegration
    /// When this build's provisioning profile expires; `nil` when it has none, as a debug build signed ad hoc.
    @ObservationIgnored private let profileExpiry: Date?
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var scheduledSync: Task<Void, Never>?

    init(
        sync: LibrarySync?,
        library: ProjectLibrary,
        settings: SettingsStore,
        system: any SystemIntegration,
        profileExpiry: Date?,
        now: @escaping () -> Date = Date.init,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.sync = sync
        self.library = library
        self.settings = settings
        self.system = system
        self.profileExpiry = profileExpiry
        self.now = now
        self.sleep = sleep
        sync?.onLocalChange = { [weak self] in
            self?.syncSoon()
        }
        sync?.onFirstSync = { [weak self] in
            self?.showsFirstSyncNotice = true
        }
        // Sync already stopped itself; the setting only follows, so Settings keeps saying why.
        sync?.onStop = { [weak self] _ in
            self?.settings.update { $0.syncsWithICloud = false }
        }
    }

    var status: SyncStatus {
        sync?.status ?? .unavailable
    }

    var issues: [String] {
        sync?.issues ?? []
    }

    var isOn: Bool {
        settings.settings.syncsWithICloud
    }

    // MARK: - Lifecycle

    /// Starts sync at launch, when Settings has it on.
    func start() {
        guard let sync, isOn else {
            return
        }
        Task {
            // Turned off again before this ran, it stays off.
            if isOn {
                await sync.start()
            }
        }
    }

    func setOn(_ isOn: Bool) {
        settings.update { $0.syncsWithICloud = isOn }
        guard let sync else {
            return
        }
        if isOn {
            start()
        } else {
            scheduledSync?.cancel()
            sync.stop()
        }
    }

    /// Coming forward applies what was fetched meanwhile and syncs; leaving holds what arrives until Reqling is back.
    func setActive(_ isActive: Bool) {
        guard let sync else {
            return
        }
        Task {
            await sync.setActive(isActive)
        }
    }

    /// Sync Now: fetches and sends, trying again whatever failed before.
    func syncNow() {
        guard let sync else {
            return
        }
        Task {
            await sync.syncNow(retryingFailures: true)
        }
    }

    /// Writes what sync keeps on this Mac, as Reqling quits.
    func flush() {
        scheduledSync?.cancel()
        sync?.flush()
    }

    /// Syncs once edits pause, fetching first, so a deletion goes out too (`LibrarySync.onLocalChange`).
    private func syncSoon() {
        scheduledSync?.cancel()
        scheduledSync = Task { [weak self, sleep] in
            do {
                try await sleep(Self.localChangeDelay)
            } catch {
                return
            }
            await self?.sync?.syncNow()
        }
    }

    // MARK: - Choices

    var accountChangeCandidates: [AccountChangeCandidate] {
        sync?.accountChangeCandidates ?? []
    }

    /// Whether `candidate` merges into the new account: ticked unless it synced with the account before, whose data it
    /// may be, until the person says otherwise.
    func isMerging(_ candidate: AccountChangeCandidate) -> Bool {
        mergeOverrides[candidate.id] ?? !candidate.syncedWithPreviousAccount
    }

    func setMerging(_ candidate: AccountChangeCandidate, _ isMerging: Bool) {
        mergeOverrides[candidate.id] = isMerging
    }

    /// Merges the ticked projects, and Global with them unless none is, into the account now signed in.
    func mergeTickedProjects() {
        let merging = Set(accountChangeCandidates.filter(isMerging).map(\.id))
        resolveAccountChange(merging: merging)
    }

    /// Keeps every project on this Mac out of the account now signed in, Global too, and syncs only what it holds.
    func useAccountDataOnly() {
        resolveAccountChange(merging: [])
    }

    private func resolveAccountChange(merging: Set<ProjectID>) {
        mergeOverrides = [:]
        Task {
            await sync?.resolveAccountChange(merging: merging)
        }
    }

    /// The projects another Mac deleted together, by name, which wait for `confirmDeletions`.
    var deletionsAwaitingConfirmation: [String] {
        guard case .confirmingDeletions(let projects) = status else {
            return []
        }
        return projects.map { library.project($0)?.name ?? "A project" }
    }

    /// The projects held back because they hold changes this version can't read, by name; edits made here wait.
    var heldBackProjects: [String] {
        (sync?.deferredProjects ?? []).map { library.project($0)?.name ?? "A project" }.sorted()
    }

    /// Answers the question several projects deleted on another Mac at once pose: to the Trash, or kept here.
    func confirmDeletions(_ confirmed: Bool) {
        Task {
            await sync?.confirmDeletions(confirmed)
        }
    }

    var isGlobalDetached: Bool {
        sync?.isGlobalDetached ?? false
    }

    func attachGlobal() {
        Task {
            await sync?.attachGlobal()
        }
    }

    // MARK: - Settings links

    var backupDirectory: URL? {
        sync?.backupDirectory
    }

    func showBackup() {
        if let backupDirectory {
            system.reveal(backupDirectory)
        }
    }

    func openICloudSettings() {
        if let url = Self.iCloudSettingsURL {
            system.open(url)
        }
    }

    /// When this build stops opening, once that's within `expiryWarningInterval`.
    var profileExpiryWarning: Date? {
        profileExpiry.flatMap { $0.timeIntervalSince(now()) < Self.expiryWarningInterval ? $0 : nil }
    }
}
