import ReqlingKit
import SwiftUI

/// The running version, whether a newer one exists, downloading and installing it, and the notes of what changed.
struct AppUpdatesSettingsPage: View {
    let model: AppModel

    var body: some View {
        let updates = model.updates
        VStack(alignment: .leading, spacing: SettingsScreenLayout.settingsSectionSpacing) {
            SettingsFormSection("Reqling") {
                SettingsFormRow {
                    SettingsResponsiveControlRow("Version") {
                        HStack(spacing: 10) {
                            Spacer()
                            Text(updates.currentVersionString ?? "Unknown")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                            Button("Check Now") { model.checkForUpdates() }
                                .disabled(updates.isChecking)
                        }
                    }
                }
                SettingsFormRow {
                    SettingsResponsiveControlRow("Status") {
                        AppUpdateStatusView(updates: updates)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                if let action = AppUpdateAction(updates) {
                    SettingsFormRow {
                        AppUpdateActionView(action: action, model: model)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                SettingsToggleRow(
                    "Check for updates automatically",
                    helpText: "Reqling checks GitHub when it opens and every 6 hours.",
                    isOn: Binding(
                        get: { model.settings.settings.checksForUpdatesAutomatically },
                        set: { model.setChecksForUpdatesAutomatically($0) }
                    ),
                    showsDivider: false
                )
            }
            if showsNotes(updates), !updates.releaseNotes.isEmpty {
                SettingsFormSection("What's New") {
                    ForEach(Array(updates.releaseNotes.enumerated()), id: \.element.tagName) { index, note in
                        SettingsFormRow(showsDivider: index < updates.releaseNotes.count - 1) {
                            AppUpdateReleaseNoteView(note: note)
                        }
                    }
                }
            }
        }
    }

    /// Notes describe what an update brings, so they show only while one is on offer or ready.
    private func showsNotes(_ updates: AppUpdateManager) -> Bool {
        if case .updateAvailable = updates.status {
            return true
        }
        return updates.stagedUpdate != nil
    }
}

private struct AppUpdateStatusView: View {
    let updates: AppUpdateManager

    var body: some View {
        if updates.isChecking {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking…").foregroundStyle(.secondary)
            }
        } else {
            switch updates.status {
            case .idle:
                Text("Not checked yet").foregroundStyle(.secondary)
            case .upToDate:
                upToDate.foregroundStyle(.secondary)
            case .updateAvailable(let release, _):
                Label("Version \(release.version.description) is available", systemImage: "arrow.down.circle.fill")
                    .foregroundStyle(.green)
            case .unavailable(let reason):
                Label(reason.message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    /// A `Text` date style, so the time follows the environment's time zone and locale.
    private var upToDate: Text {
        guard let date = updates.lastCheckedAt else {
            return Text("Up to date")
        }
        return Text("Up to date · checked \(Text(date, style: .time))")
    }
}

/// What the action row offers, from the download state and the last check.
enum AppUpdateAction: Equatable {
    case download(version: String)
    /// Only a download in flight can stop: a check is brief, and staging and installing must finish once begun.
    case progress(String, fraction: Double?, cancellable: Bool)
    case install(version: String)
    case failed(String)

    @MainActor
    init?(_ updates: AppUpdateManager) {
        switch updates.downloadState {
        case .checkingLatestRelease:
            self = .progress("Checking…", fraction: nil, cancellable: false)
        case .downloading(let release, let progress):
            self = .progress("Downloading \(release.version.description)…", fraction: progress, cancellable: true)
        case .staging(let release):
            self = .progress("Verifying \(release.version.description)…", fraction: nil, cancellable: false)
        case .readyToInstall(let staged):
            self = .install(version: staged.release.version.description)
        case .installing:
            self = .progress("Installing…", fraction: nil, cancellable: false)
        case .failed(let failure):
            self = .failed(failure.message)
        case .idle:
            guard case .updateAvailable(let release, _) = updates.status else {
                return nil
            }
            self = .download(version: release.version.description)
        }
    }
}

private struct AppUpdateActionView: View {
    let action: AppUpdateAction
    let model: AppModel

    var body: some View {
        switch action {
        case .download(let version):
            Button("Download \(version)") { model.downloadUpdate() }
                .buttonStyle(.borderedProminent)
        case .progress(let label, let fraction, let cancellable):
            HStack(spacing: 10) {
                Text(label).foregroundStyle(.secondary)
                if let fraction {
                    ProgressView(value: fraction)
                        .frame(width: 140)
                        .accessibilityLabel("Download progress")
                } else {
                    ProgressView().controlSize(.small)
                }
                if cancellable {
                    Button("Cancel") { model.cancelUpdateDownload() }
                }
            }
        case .install(let version):
            HStack(spacing: 10) {
                Text("Version \(version) is ready.").foregroundStyle(.secondary)
                Button("Install & Relaunch") { model.installUpdate() }
                    .buttonStyle(.borderedProminent)
            }
        case .failed(let message):
            VStack(alignment: .trailing, spacing: 6) {
                Label(message, systemImage: "xmark.octagon")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Button("Try Again") { model.downloadUpdate() }
            }
        }
    }
}

private struct AppUpdateReleaseNoteView: View {
    let note: AppUpdateReleaseNote

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(note.tagName).font(.headline)
            Text(Self.rendered(note.changelogMarkdown))
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Inline Markdown with line breaks kept, so a list or headings still read as lines; full block rendering is more
    /// than release notes need.
    static func rendered(_ markdown: String) -> AttributedString {
        let text = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return AttributedString("No notes for this release.")
        }
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
