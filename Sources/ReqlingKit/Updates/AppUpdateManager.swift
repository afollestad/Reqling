import Foundation
import Observation

/// Every 6 hours, as GitHub's unauthenticated rate limit comfortably allows with conditional requests.
private let appUpdateAutomaticCheckInterval: Duration = .seconds(21_600)

public enum AppUpdateCheckTrigger: Equatable, Sendable {
    case automatic
    case manual
}

public enum AppUpdateStatus: Equatable, Sendable {
    case idle
    case updateAvailable(AppUpdateRelease, currentVersion: AppUpdateVersion)
    case upToDate(AppUpdateRelease, currentVersion: AppUpdateVersion)
    case unavailable(AppUpdateUnavailableReason)
}

/// The check interval, clock, and sleep, injected so tests drive the schedule without waiting.
public struct AppUpdateScheduleTiming: Sendable {
    public static let live = AppUpdateScheduleTiming(
        automaticCheckInterval: appUpdateAutomaticCheckInterval,
        now: { Date() },
        sleep: { duration in
            try await Task.sleep(for: duration)
        }
    )

    let automaticCheckInterval: Duration
    let now: @Sendable () -> Date
    let sleep: @Sendable (Duration) async throws -> Void

    public init(
        automaticCheckInterval: Duration,
        now: @escaping @Sendable () -> Date,
        sleep: @escaping @Sendable (Duration) async throws -> Void
    ) {
        self.automaticCheckInterval = automaticCheckInterval
        self.now = now
        self.sleep = sleep
    }
}

/// Checks GitHub for a newer Reqling, downloads and stages it on request, and installs it with a relaunch.
///
/// Automatic checks run at launch and every 6 hours while on; their failures stay quiet (a laptop offline is not news),
/// while a manual check reports what went wrong. Overlapping checks share one request.
@MainActor
@Observable
public final class AppUpdateManager {
    @ObservationIgnored private let currentVersionText: String?
    private let releaseClient: any AppUpdateReleaseClient
    private let downloader: (any AppUpdateDownloading)?
    private let stager: (any AppUpdateStaging)?
    private let installer: (any AppUpdateInstalling)?
    private let scheduleTiming: AppUpdateScheduleTiming
    private var didStartAutomaticChecks = false
    private var automaticScheduleTask: Task<Void, Never>?
    private var activeCheckTask: Task<AppUpdateCheckResult, Never>?
    private var activeCheckID: UUID?
    private var activeDownloadTask: Task<StagedAppUpdate, any Error>?
    private var activeDownloadID: UUID?

    public private(set) var status: AppUpdateStatus = .idle
    public private(set) var isChecking = false
    public private(set) var latestRelease: AppUpdateRelease?
    public private(set) var releaseNotes: [AppUpdateReleaseNote] = []
    public private(set) var currentVersion: AppUpdateVersion?
    /// When a check last reached GitHub; a failed check leaves it alone, so "checked at" never describes one.
    public private(set) var lastCheckedAt: Date?
    public private(set) var lastManualFailure: AppUpdateUnavailableReason?
    public private(set) var downloadState: AppUpdateDownloadState = .idle
    public private(set) var stagedUpdate: StagedAppUpdate?
    /// The staged update to offer a restart for; the window shows an alert while it is set.
    public var restartPrompt: StagedAppUpdate?

    /// `downloader`, `stager`, and `installer` are `nil` in a build that only checks.
    public init(
        releaseClient: any AppUpdateReleaseClient,
        currentVersion: String?,
        downloader: (any AppUpdateDownloading)? = nil,
        stager: (any AppUpdateStaging)? = nil,
        installer: (any AppUpdateInstalling)? = nil,
        scheduleTiming: AppUpdateScheduleTiming = .live
    ) {
        currentVersionText = currentVersion
        self.releaseClient = releaseClient
        self.downloader = downloader
        self.stager = stager
        self.installer = installer
        self.scheduleTiming = scheduleTiming
        self.currentVersion = currentVersion.flatMap(AppUpdateVersion.init)
    }

    public func startAutomaticChecks() {
        guard !didStartAutomaticChecks else {
            return
        }

        didStartAutomaticChecks = true
        Task { [weak self] in
            await self?.loadStagedUpdateIfAvailable()
            await self?.runCheck(trigger: .automatic)
        }
    }

    @discardableResult
    public func forceCheck() async -> AppUpdateCheckResult {
        await runCheck(trigger: .manual)
    }

    public var currentVersionString: String? {
        currentVersionText
    }

    /// Whether the gear shows a badge, and which.
    public var badgeState: AppUpdateBadgeState {
        if stagedUpdate != nil {
            return .readyToInstall
        }
        if case .updateAvailable = status {
            return .updateAvailable
        }
        return .none
    }

    public func stopAutomaticChecks() {
        didStartAutomaticChecks = false
        automaticScheduleTask?.cancel()
        automaticScheduleTask = nil
    }

    public func dismissRestartPrompt() {
        restartPrompt = nil
    }

    public func loadStagedUpdateIfAvailable() async {
        guard stagedUpdate == nil,
              let stager else {
            return
        }

        do {
            guard let loadedUpdate = try await stager.loadValidatedStagedUpdate() else {
                return
            }
            stagedUpdate = loadedUpdate
            downloadState = .readyToInstall(loadedUpdate)
            restartPrompt = loadedUpdate
        } catch {
            downloadState = .failed(.from(error))
        }
    }

    @discardableResult
    public func downloadLatestUpdate() async -> StagedAppUpdate? {
        if let activeDownloadTask {
            return try? await activeDownloadTask.value
        }

        downloadState = .checkingLatestRelease
        let checkResult = await forceCheck()
        guard case .updateAvailable(let snapshot) = checkResult else {
            downloadState = .failed(AppUpdateFailure(message: "No newer version of Reqling is available to download."))
            return nil
        }
        guard let downloader,
              let stager else {
            downloadState = .failed(AppUpdateFailure(message: "This build of Reqling can't download updates."))
            return nil
        }

        let release = snapshot.latestRelease
        downloadState = .downloading(release, progress: 0)
        let download = startDownloadTask(
            release: release,
            downloader: downloader,
            stager: stager
        )
        activeDownloadTask = download.task
        activeDownloadID = download.id

        do {
            return try await finishDownloadTask(download)
        } catch is CancellationError {
            clearActiveDownload(id: download.id, state: .idle)
            return nil
        } catch {
            clearActiveDownload(id: download.id, state: .failed(.from(error)))
            return nil
        }
    }

    public func cancelDownload() {
        activeDownloadTask?.cancel()
        activeDownloadTask = nil
        activeDownloadID = nil
        downloadState = .idle
    }

    public func installDownloadedUpdate() async {
        guard let stagedUpdate else {
            downloadState = .failed(AppUpdateFailure(message: "No downloaded update is ready to install."))
            return
        }
        guard let installer else {
            downloadState = .failed(AppUpdateFailure(message: "This build of Reqling can't install updates."))
            return
        }

        downloadState = .installing(stagedUpdate)
        restartPrompt = nil
        do {
            try await installer.installAndRelaunch(stagedUpdate: stagedUpdate)
        } catch {
            downloadState = .failed(.from(error))
        }
    }

    @discardableResult
    public func runCheck(trigger: AppUpdateCheckTrigger) async -> AppUpdateCheckResult {
        let check = currentOrStartedCheck()
        let result = await check.task.value

        if activeCheckID == check.id {
            activeCheckTask = nil
            activeCheckID = nil
            isChecking = false
        }

        apply(result, trigger: trigger)
        scheduleNextAutomaticCheckIfNeeded()
        return result
    }

}

private extension AppUpdateManager {
    func startDownloadTask(
        release: AppUpdateRelease,
        downloader: any AppUpdateDownloading,
        stager: any AppUpdateStaging
    ) -> (id: UUID, task: Task<StagedAppUpdate, any Error>) {
        let downloadID = UUID()
        let task = Task.detached(priority: .utility) { [weak self, downloader, stager] in
            let downloadedZIPURL = try await downloader.download(release: release) { progress in
                await MainActor.run {
                    guard self?.activeDownloadID == downloadID else {
                        return
                    }
                    self?.downloadState = .downloading(release, progress: progress)
                }
            }
            try Task.checkCancellation()
            await MainActor.run {
                guard self?.activeDownloadID == downloadID else {
                    return
                }
                self?.downloadState = .staging(release)
            }
            try Task.checkCancellation()
            return try await stager.stageDownloadedUpdate(
                release: release,
                downloadedZIPURL: downloadedZIPURL
            )
        }
        return (downloadID, task)
    }

    func finishDownloadTask(_ download: (id: UUID, task: Task<StagedAppUpdate, any Error>)) async throws -> StagedAppUpdate? {
        let stagedUpdate = try await download.task.value
        guard activeDownloadID == download.id else {
            return stagedUpdate
        }
        activeDownloadTask = nil
        activeDownloadID = nil
        self.stagedUpdate = stagedUpdate
        downloadState = .readyToInstall(stagedUpdate)
        restartPrompt = stagedUpdate
        return stagedUpdate
    }

    func clearActiveDownload(id: UUID, state: AppUpdateDownloadState) {
        guard activeDownloadID == id else {
            return
        }
        activeDownloadTask = nil
        activeDownloadID = nil
        downloadState = state
    }

    func currentOrStartedCheck() -> (id: UUID, task: Task<AppUpdateCheckResult, Never>) {
        if let activeCheckTask, let activeCheckID {
            return (activeCheckID, activeCheckTask)
        }

        let checkID = UUID()
        let releaseClient = releaseClient
        let currentVersion = currentVersion
        let currentVersionText = currentVersionText
        let task = Task.detached(priority: .utility) {
            await Self.check(releaseClient, currentVersion: currentVersion, text: currentVersionText)
        }
        activeCheckID = checkID
        activeCheckTask = task
        isChecking = true
        return (checkID, task)
    }

    func apply(_ result: AppUpdateCheckResult, trigger: AppUpdateCheckTrigger) {
        switch result {
        case .updateAvailable(let snapshot):
            lastCheckedAt = scheduleTiming.now()
            latestRelease = snapshot.latestRelease
            releaseNotes = snapshot.releaseNotes
            currentVersion = snapshot.currentVersion
            lastManualFailure = nil
            status = .updateAvailable(snapshot.latestRelease, currentVersion: snapshot.currentVersion)
        case .upToDate(let snapshot):
            lastCheckedAt = scheduleTiming.now()
            latestRelease = snapshot.latestRelease
            releaseNotes = snapshot.releaseNotes
            currentVersion = snapshot.currentVersion
            lastManualFailure = nil
            status = .upToDate(snapshot.latestRelease, currentVersion: snapshot.currentVersion)
        case .unavailable(let reason):
            guard trigger == .manual else {
                return
            }
            lastManualFailure = reason
            status = .unavailable(reason)
        }
    }

    func scheduleNextAutomaticCheckIfNeeded() {
        guard didStartAutomaticChecks else {
            return
        }

        automaticScheduleTask?.cancel()
        let scheduleTiming = scheduleTiming
        automaticScheduleTask = Task { [weak self] in
            do {
                try await scheduleTiming.sleep(scheduleTiming.automaticCheckInterval)
            } catch {
                return
            }
            await self?.runCheck(trigger: .automatic)
        }
    }
}

extension AppUpdateManager {
    /// The newer releases' notes, newest first, or the latest release's alone when nothing is newer.
    nonisolated static func check(
        _ client: any AppUpdateReleaseClient,
        currentVersion: AppUpdateVersion?,
        text: String?
    ) async -> AppUpdateCheckResult {
        guard let currentVersion else {
            return .unavailable(.malformedVersion(text ?? ""))
        }
        switch await client.latestRelease() {
        case .installable(let feed):
            let newer = feed.releaseNotes.filter { $0.version > currentVersion }.sorted { $0.version > $1.version }
            let snapshot = AppUpdateCheckSnapshot(
                latestRelease: feed.latestRelease,
                currentVersion: currentVersion,
                releaseNotes: newer.isEmpty ? [feed.latestRelease.releaseNote] : newer
            )
            return feed.latestRelease.version > currentVersion ? .updateAvailable(snapshot) : .upToDate(snapshot)
        case .unavailable(let reason):
            return .unavailable(reason)
        }
    }
}

/// The gear's badge: an accent dot when an update can be downloaded, green once one is ready to install.
public enum AppUpdateBadgeState: Equatable, Sendable {
    case none
    case updateAvailable
    case readyToInstall

    public var accessibilityValue: String {
        switch self {
        case .none: "No update available"
        case .updateAvailable: "Update available"
        case .readyToInstall: "Update ready to install"
        }
    }
}
