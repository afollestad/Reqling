import ReqlingKit
import SwiftUI

/// iCloud sync: on or off, where it stands, and the choices only the person can make, each shown only while it's open.
struct ICloudSettingsPage: View {
    let model: ICloudSyncModel

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsScreenLayout.settingsSectionSpacing) {
            SettingsFormSection("iCloud") {
                SettingsToggleRow(
                    "Sync with iCloud",
                    helpText: Self.syncHelp,
                    isOn: Binding(get: { model.isOn && model.sync != nil }, set: { model.setOn($0) })
                )
                .disabled(model.sync == nil)
                SettingsFormRow {
                    SettingsResponsiveControlRow("Status") {
                        ICloudStatusView(status: model.status)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                ForEach(model.issues, id: \.self) { issue in
                    SettingsFormRow {
                        SettingsErrorLabel(issue)
                    }
                }
                SettingsFormRow(showsDivider: false) {
                    ICloudActions(model: model)
                }
            }
            if case .accountChanged = model.status {
                ICloudAccountChoice(model: model)
            }
            if !model.deletionsAwaitingConfirmation.isEmpty {
                ICloudDeletionsChoice(model: model)
            }
            if !model.heldBackProjects.isEmpty {
                SettingsFormSection("Waiting for an Update") {
                    SettingsFormRow(showsDivider: false) {
                        Text(Self.heldBackMessage(model.heldBackProjects))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if model.isGlobalDetached {
                SettingsFormSection("Global") {
                    SettingsFormRow(showsDivider: false) {
                        SettingsResponsiveControlRow("Kept on this Mac", helpText: Self.globalHelp, horizontalControlSizing: .intrinsic) {
                            Button("Sync Global") { model.attachGlobal() }
                        }
                    }
                }
            }
            if let expiry = model.profileExpiryWarning {
                SettingsFormSection("This Copy of Reqling") {
                    SettingsFormRow(showsDivider: false) {
                        SettingsErrorLabel(Self.expiryMessage(expiry))
                    }
                }
            }
        }
    }

    private static let syncHelp = "Projects in Reqling's own folder, Global, and current values, end-to-end encrypted. Projects "
        + "elsewhere, such as in a repository, run history, and the active environment stay on this Mac."

    private static let globalHelp = "You kept Global out of this iCloud account. Syncing it merges this Mac's Global and "
        + "current values with the account's."

    static func heldBackMessage(_ names: [String]) -> String {
        "\(names.map { "“\($0)”" }.joined(separator: ", ")) changed on a Mac with a newer Reqling, so syncing "
            + "\(names.count == 1 ? "it" : "them") waits until you update. What you change here meanwhile syncs then."
    }

    static func expiryMessage(_ date: Date) -> String {
        "This copy of Reqling stops opening after \(date.formatted(date: .abbreviated, time: .omitted)), when its iCloud "
            + "permission expires. Update Reqling before then."
    }
}

/// Open iCloud Settings, Show Backup in Finder, and Sync Now: secondary actions, outside the toggle's label.
private struct ICloudActions: View {
    let model: ICloudSyncModel

    var body: some View {
        HStack(spacing: 8) {
            Button("Open iCloud Settings…") { model.openICloudSettings() }
                .help("Where you sign in to iCloud, or delete Reqling's data from it")
            if model.backupDirectory != nil {
                Button("Show Backup in Finder") { model.showBackup() }
                    .help("The copy of your projects, Global, and current values made before this Mac first synced")
            }
            Spacer(minLength: 0)
            Button("Sync Now") { model.syncNow() }
                .disabled(!canSyncNow)
        }
    }

    private var canSyncNow: Bool {
        guard model.isOn, model.sync != nil else {
            return false
        }
        switch model.status {
        case .syncing, .unavailable, .off, .accountChanged, .confirmingDeletions, .stopped:
            return false
        case .signedOut, .upToDate, .failed:
            return true
        }
    }
}

private struct ICloudStatusView: View {
    let status: SyncStatus

    var body: some View {
        switch status {
        case .unavailable:
            Text("This build of Reqling can't use iCloud.")
                .foregroundStyle(.secondary)
        case .off:
            Text("Off")
                .foregroundStyle(.secondary)
        case .signedOut:
            Text("Sign in to iCloud to sync.")
                .foregroundStyle(.secondary)
        case .syncing:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Syncing…")
                    .foregroundStyle(.secondary)
            }
        case .upToDate(let date):
            Label {
                Text("Synced \(date, format: Date.FormatStyle(date: .abbreviated, time: .shortened))")
            } icon: {
                Image(systemName: "checkmark.circle.fill")
            }
            .foregroundStyle(.green)
        case .accountChanged:
            Text("Paused: a different iCloud account is signed in.")
                .foregroundStyle(.orange)
        case .confirmingDeletions:
            Text("Paused: another Mac deleted several projects.")
                .foregroundStyle(.orange)
        case .stopped(.dataDeleted):
            SettingsErrorLabel("Reqling's iCloud data was deleted, so sync turned off. Turning it on uploads this Mac's projects again.")
        case .stopped(.encryptionReset):
            SettingsErrorLabel("Your iCloud encrypted data was reset, so sync turned off. Turning it on uploads this Mac's projects again.")
        case .failed(let message):
            SettingsErrorLabel(message)
        }
    }
}

/// Which of this Mac's projects merge into an iCloud account other than the one they last synced with.
struct ICloudAccountChoice: View {
    let model: ICloudSyncModel

    var body: some View {
        let candidates = model.accountChangeCandidates
        SettingsFormSection("Another iCloud Account") {
            SettingsFormRow {
                Text(Self.explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(candidates) { candidate in
                SettingsToggleRow(
                    candidate.name,
                    helpText: candidate.syncedWithPreviousAccount ? "Synced with the other account." : nil,
                    isOn: Binding(get: { model.isMerging(candidate) }, set: { model.setMerging(candidate, $0) })
                )
            }
            SettingsFormRow(showsDivider: false) {
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Button("Use This Account's Data Only") { model.useAccountDataOnly() }
                    Button("Merge Chosen Projects") { model.mergeTickedProjects() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    static let explanation = "This Mac's projects last synced with another iCloud account. The ones you choose merge "
        + "into this one, with their secret values, and Global and current values go along unless you choose none. The rest "
        + "stay on this Mac, out of sync."
}

/// Whether projects another Mac deleted together go to the Trash here too.
private struct ICloudDeletionsChoice: View {
    let model: ICloudSyncModel

    var body: some View {
        SettingsFormSection("Deleted on Another Mac") {
            SettingsFormRow {
                Text(Self.explanation(model.deletionsAwaitingConfirmation))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SettingsFormRow(showsDivider: false) {
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Button("Keep on This Mac") { model.confirmDeletions(false) }
                    Button("Move to Trash", role: .destructive) { model.confirmDeletions(true) }
                }
            }
        }
    }

    static func explanation(_ names: [String]) -> String {
        "Another Mac deleted \(names.map { "“\($0)”" }.joined(separator: ", ")). Move them to the Trash here too, where "
            + "Finder can put them back, or keep them on this Mac, out of sync?"
    }
}
