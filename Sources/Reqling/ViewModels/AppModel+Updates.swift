import Foundation
import ReqlingKit

/// The updater's actions, for Settings ▸ App Updates, the gear's badge, and the restart prompt.
extension AppModel {
    /// Starts the schedule when Settings has automatic checks on, and otherwise only restores an update staged by an
    /// earlier launch, so turning checks off never hides one that is ready.
    func startUpdates() {
        if settings.settings.checksForUpdatesAutomatically {
            updates.startAutomaticChecks()
        } else {
            Task { await updates.loadStagedUpdateIfAvailable() }
        }
    }

    func setChecksForUpdatesAutomatically(_ isOn: Bool) {
        settings.update { $0.checksForUpdatesAutomatically = isOn }
        if isOn {
            updates.startAutomaticChecks()
        } else {
            updates.stopAutomaticChecks()
        }
    }

    func checkForUpdates() {
        Task { await updates.forceCheck() }
    }

    func downloadUpdate() {
        Task { await updates.downloadLatestUpdate() }
    }

    func cancelUpdateDownload() {
        updates.cancelDownload()
    }

    /// Asks about unsaved edits before the install helper starts, not when Reqling quits: once started, the helper
    /// installs on whatever quit comes next, so a refused quit would leave it armed.
    func installUpdate() {
        guard confirmTermination() else {
            return
        }
        isQuittingForUpdate = true
        Task {
            await updates.installDownloadedUpdate()
            if case .failed = updates.downloadState {
                isQuittingForUpdate = false
            }
        }
    }

    func dismissUpdateRestartPrompt() {
        updates.dismissRestartPrompt()
    }

    /// The gear opens App Updates while it shows a badge, and Settings' last page otherwise.
    func openSettingsFromToolbar() {
        if isShowingSettings {
            closeSettings()
        } else {
            showSettings(updates.badgeState == .none ? nil : .updates)
        }
    }
}
