import ReqlingKit
import SwiftUI

/// The protoc that compiles project protos (found, overridden, or installed by Reqling) and gRPC call defaults.
struct GRPCSettingsPage: View {
    let settings: SettingsStore
    let tooling: ProtocToolingModel

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsScreenLayout.settingsSectionSpacing) {
            SettingsFormSection("protoc") {
                SettingsFormRow {
                    SettingsResponsiveControlRow("Detected", helpText: Self.detectedHelp) {
                        ProtocDetectionSummary(detection: tooling.detection)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                SettingsFormRow {
                    SettingsResponsiveControlRow("Reqling's protoc", helpText: installHelp) {
                        ProtocInstallControl(tooling: tooling, alignment: .trailing)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                SettingsFormRow(showsDivider: false) {
                    SettingsResponsiveControlRow("Custom path", helpText: Self.overrideHelp) {
                        ProtocOverrideField(tooling: tooling)
                    }
                }
            }
            SettingsFormSection("Calls") {
                SettingsFormRow(showsDivider: false) {
                    SettingsResponsiveControlRow("Deadline", helpText: Self.deadlineHelp, horizontalControlSizing: .intrinsic) {
                        Stepper(value: deadline, in: AppSettings.timeoutRange, step: 5) {
                            Text("\(Int(settings.settings.grpcDeadlineSeconds)) seconds")
                                .monospacedDigit()
                        }
                    }
                }
            }
        }
        // Each visit searches again, so a protoc installed with Homebrew while Reqling runs shows up.
        .task { await tooling.refresh() }
    }

    private static let detectedHelp =
        "Reqling uses the custom path when one is set; otherwise its own install, then Homebrew, /usr/local/bin, and PATH."

    private static let overrideHelp = "A protoc to use instead of searching. Leave it empty to search."

    private static let deadlineHelp = """
        How long a gRPC call may run, \(Int(AppSettings.timeoutRange.lowerBound))–\(Int(AppSettings.timeoutRange.upperBound)) \
        seconds, unless the request sets its own. Client-streaming and bidirectional calls sent from the editor stay open \
        until you end them, so they get none unless the request sets one.
        """

    private var installHelp: String {
        "Downloads protoc \(tooling.installVersion) from GitHub, checks its SHA-256, and keeps it in Reqling's own folder."
    }

    private var deadline: Binding<Double> {
        Binding(get: { settings.settings.grpcDeadlineSeconds }, set: { value in settings.update { $0.grpcDeadlineSeconds = value } })
    }
}

/// The protoc a compile would use, where it came from, and its version.
struct ProtocDetectionSummary: View {
    let detection: ProtocToolingModel.Detection

    var body: some View {
        switch detection {
        case .unknown:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Searching…")
                    .foregroundStyle(.secondary)
            }
        case .found(let installation):
            let path = (installation.executable.path as NSString).abbreviatingWithTildeInPath
            VStack(alignment: .trailing, spacing: 2) {
                Text("protoc \(installation.version) · \(Self.title(for: installation.source))")
                Text(path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(path)
            }
        case .missing:
            Text("Not installed")
                .foregroundStyle(.secondary)
        case .invalidOverride(let message):
            SettingsErrorLabel(message)
        }
    }

    static func title(for source: ProtocSource) -> String {
        switch source {
        case .settingsOverride: "Custom path"
        case .managed: "Installed by Reqling"
        case .homebrew: "Homebrew"
        case .usrLocal: "/usr/local/bin"
        case .path: "PATH"
        }
    }
}

/// Install or reinstall Reqling's protoc, its live progress with Cancel, or why it failed. Settings and Project
/// Settings both show it over the one shared `ProtocToolingModel`, so either reflects an install started in the other.
struct ProtocInstallControl: View {
    let tooling: ProtocToolingModel
    let alignment: HorizontalAlignment

    var body: some View {
        switch tooling.installState {
        case .idle:
            Button(tooling.hasCurrentManagedInstall ? "Reinstall" : "Install protoc \(tooling.installVersion)") {
                tooling.install()
            }
        case .installing(let phase):
            ProtocInstallProgress(phase: phase) { tooling.cancelInstall() }
        case .failed(let message):
            VStack(alignment: alignment, spacing: 6) {
                SettingsErrorLabel(message)
                Button("Try Again") { tooling.install() }
            }
        }
    }
}

private struct ProtocInstallProgress: View {
    private static let barWidth: CGFloat = 160

    let phase: ProtocInstallPhase?
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                if let fraction {
                    ProgressView(value: fraction)
                        .frame(width: Self.barWidth)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .frame(width: Self.barWidth)
                }
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .accessibilityElement(children: .combine)
            Button("Cancel", action: onCancel)
        }
    }

    /// `nil` for phases with no measurable progress, which show an indeterminate bar.
    private var fraction: Double? {
        guard case .downloading(let received, let expected?)? = phase, expected > 0 else {
            return nil
        }
        return min(Double(received) / Double(expected), 1)
    }

    private var status: String {
        switch phase {
        case nil:
            "Starting…"
        case .downloading(let received, let expected?)?:
            "Downloading \(Self.bytes(received)) of \(Self.bytes(expected))"
        case .downloading(let received, .none)?:
            "Downloading \(Self.bytes(received))"
        case .verifying?:
            "Verifying checksum…"
        case .extracting?:
            "Unpacking…"
        }
    }

    private static func bytes(_ count: Int64) -> String {
        count.formatted(.byteCount(style: .file))
    }
}

/// The Settings override. Edits save on Return, on leaving the field, or through Choose… and Clear; each save
/// recompiles every project, so a keystroke must not.
private struct ProtocOverrideField: View {
    @Bindable var tooling: ProtocToolingModel
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            TextField("Custom protoc path", text: $tooling.overridePathDraft, prompt: Text("Automatic"))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .frame(minWidth: 160)
                .focused($isFocused)
                .onSubmit { tooling.commitOverridePath() }
            Button("Choose…") { tooling.chooseOverridePath() }
            Button("Clear") { tooling.clearOverridePath() }
                .disabled(tooling.overridePath == nil && tooling.overridePathDraft.isEmpty)
        }
        .onChange(of: isFocused) { _, focused in
            if !focused {
                tooling.commitOverridePath()
            }
        }
    }
}
