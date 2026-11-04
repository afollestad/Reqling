import Foundation

/// Swaps the staged app in for the running one: a helper script, started before Reqling quits, waits for this process
/// to exit, moves the installed app to a backup, copies the staged app into place, and relaunches it. Any failure
/// restores the backup and the staged metadata and reopens the old app, so a failed install never leaves Reqling
/// missing. The metadata is quarantined while the swap runs, so a relaunch mid-install cannot re-offer the update.
public struct DefaultAppUpdateInstaller: AppUpdateInstalling {
    private let paths: AppUpdateStoragePaths
    private let target: AppUpdateTarget
    private let commands: any CommandRunning
    private let processIdentifier: @Sendable () -> Int32
    private let launchHelper: @Sendable (_ script: URL, _ arguments: [String]) throws -> Void
    private let terminate: @Sendable () -> Void
    private let script: AppUpdateInstallHelperScript

    public init(
        updatesDirectory: URL,
        target: AppUpdateTarget,
        commands: any CommandRunning = ProcessCommandRunner(),
        processIdentifier: @escaping @Sendable () -> Int32 = { ProcessInfo.processInfo.processIdentifier },
        launchHelper: @escaping @Sendable (URL, [String]) throws -> Void = DefaultAppUpdateInstaller.launchWithZsh,
        terminate: @escaping @Sendable () -> Void,
        script: AppUpdateInstallHelperScript = .live
    ) {
        paths = AppUpdateStoragePaths(updatesDirectory: updatesDirectory)
        self.target = target
        self.commands = commands
        self.processIdentifier = processIdentifier
        self.launchHelper = launchHelper
        self.terminate = terminate
        self.script = script
    }

    public func installAndRelaunch(stagedUpdate: StagedAppUpdate) async throws {
        if let problem = target.installLocationProblem() {
            throw AppUpdateFailure(message: problem)
        }
        let installed = target.bundleURL.standardizedFileURL
        let stagedDirectory = try paths.validatedStagedDirectory(containing: stagedUpdate.appBundleURL)
        guard FileManager.default.fileExists(atPath: stagedUpdate.appBundleURL.path),
              FileManager.default.fileExists(atPath: paths.metadataURL.path) else {
            throw AppUpdateFailure(message: "The downloaded update is no longer there; download it again.")
        }
        for app in [installed, stagedUpdate.appBundleURL] {
            let result = try await commands.run(
                URL(fileURLWithPath: "/usr/bin/codesign"),
                arguments: ["--verify", "--deep", "--strict", "--verbose=2", app.path],
                currentDirectory: nil,
                timeout: .seconds(60)
            )
            guard result.exitCode == 0 else {
                throw AppUpdateFailure(message: "\(app.lastPathComponent) at \(app.deletingLastPathComponent().path) isn't signed correctly.")
            }
        }
        let helpers = paths.updatesDirectory.appendingPathComponent("Helpers", isDirectory: true)
        let logs = paths.updatesDirectory.appendingPathComponent("Logs", isDirectory: true)
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let helper = helpers.appendingPathComponent("install-\(UUID().uuidString).zsh")
        try script.contents.write(to: helper, atomically: true, encoding: .utf8)
        let invocation = AppUpdateInstallHelperInvocation(
            runningProcessIdentifier: processIdentifier(),
            stagedAppURL: stagedUpdate.appBundleURL,
            stagedDirectoryURL: stagedDirectory,
            targetAppURL: installed,
            backupAppURL: installed.deletingLastPathComponent().appendingPathComponent(".Reqling.app.backup-\(UUID().uuidString)", isDirectory: true),
            logURL: logs.appendingPathComponent("install-\(stagedUpdate.release.tagName.sanitizedForPathComponent)-\(UUID().uuidString).log"),
            metadataURL: paths.metadataURL,
            quarantinedMetadataURL: paths.quarantinedMetadataURL(id: UUID()),
            helperURL: helper
        )
        try launchHelper(helper, script.arguments(for: invocation))
        terminate()
    }

    /// Runs the helper detached under `/bin/zsh`; it outlives Reqling, which is the point.
    public static func launchWithZsh(_ script: URL, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [script.path] + arguments
        try process.run()
    }
}

/// The install helper and its arguments. Its text is fixed and every path arrives as a positional argument, never
/// interpolated, so no path can inject shell syntax.
public struct AppUpdateInstallHelperScript: Sendable {
    public static let live = AppUpdateInstallHelperScript(
        copyExecutableURL: URL(fileURLWithPath: "/usr/bin/ditto"),
        openExecutableURL: URL(fileURLWithPath: "/usr/bin/open"),
        relaunchGraceSeconds: 3
    )

    let copyExecutableURL: URL
    let openExecutableURL: URL
    /// How long the relaunched app gets before the backup is deleted, so a crash on launch still finds it.
    let relaunchGraceSeconds: TimeInterval

    func arguments(for invocation: AppUpdateInstallHelperInvocation) -> [String] {
        [
            "\(invocation.runningProcessIdentifier)",
            invocation.stagedAppURL.path,
            invocation.stagedDirectoryURL.path,
            invocation.targetAppURL.path,
            invocation.backupAppURL.path,
            invocation.logURL.path,
            invocation.metadataURL.path,
            invocation.quarantinedMetadataURL.path,
            invocation.helperURL.path,
            copyExecutableURL.path,
            openExecutableURL.path,
            "\(relaunchGraceSeconds)"
        ]
    }

    var contents: String {
        #"""
        set -u

        RUNNING_PID="$1"
        STAGED_APP="$2"
        STAGED_DIRECTORY="$3"
        TARGET_APP="$4"
        BACKUP_APP="$5"
        LOG_FILE="$6"
        METADATA_FILE="$7"
        QUARANTINED_METADATA_FILE="$8"
        HELPER_FILE="$9"
        COPY_EXECUTABLE="${10}"
        OPEN_EXECUTABLE="${11}"
        GRACE_SECONDS="${12}"

        exec >>"$LOG_FILE" 2>&1
        echo "Starting Reqling update install at $(date)"

        reopen_target() {
          if [ -e "$TARGET_APP" ]; then
            "$OPEN_EXECUTABLE" "$TARGET_APP" || true
          fi
        }

        restore_metadata() {
          if [ -e "$QUARANTINED_METADATA_FILE" ]; then
            mv "$QUARANTINED_METADATA_FILE" "$METADATA_FILE"
          fi
        }

        restore_backup() {
          rm -rf "$TARGET_APP"
          if [ -e "$BACKUP_APP" ]; then
            mv "$BACKUP_APP" "$TARGET_APP"
          fi
        }

        rollback() {
          echo "$1"
          restore_backup || true
          restore_metadata || true
          reopen_target
          exit 1
        }

        while kill -0 "$RUNNING_PID" 2>/dev/null; do
          sleep 0.2
        done

        if ! rm -rf "$BACKUP_APP"; then
          echo "Could not clear the update backup path"
          reopen_target
          exit 1
        fi

        if ! mv "$METADATA_FILE" "$QUARANTINED_METADATA_FILE"; then
          echo "Could not quarantine staged update metadata"
          reopen_target
          exit 1
        fi

        if [ -e "$TARGET_APP" ] && ! mv "$TARGET_APP" "$BACKUP_APP"; then
          echo "Could not move the installed app to its backup path"
          restore_metadata || true
          reopen_target
          exit 1
        fi

        if ! "$COPY_EXECUTABLE" "$STAGED_APP" "$TARGET_APP"; then
          rollback "Failed to copy staged app; restoring backup"
        fi

        if ! "$OPEN_EXECUTABLE" "$TARGET_APP"; then
          rollback "Failed to relaunch updated app; restoring backup"
        fi

        sleep "$GRACE_SECONDS"
        rm -rf "$BACKUP_APP"
        rm -f "$QUARANTINED_METADATA_FILE"
        rm -rf "$STAGED_DIRECTORY"
        rm -f "$HELPER_FILE"
        echo "Reqling update install completed at $(date)"
        exit 0
        """#
    }
}

struct AppUpdateInstallHelperInvocation: Sendable {
    let runningProcessIdentifier: Int32
    let stagedAppURL: URL
    let stagedDirectoryURL: URL
    let targetAppURL: URL
    let backupAppURL: URL
    let logURL: URL
    let metadataURL: URL
    let quarantinedMetadataURL: URL
    let helperURL: URL
}
