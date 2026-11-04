import ReqlingKit
import SwiftUI

/// The project's proto roots, entry files, and descriptor sets, headed by the saved configuration's compile status.
///
/// `status` is a plain value rather than read from `settings` here, so snapshots can show any status without a live
/// compile.
struct ProjectSettingsProtoDefinitions: View {
    let settings: ProjectSettingsModel
    let status: ProtoWorkspace.Status?
    var warnings: [ProtocDiagnostic] = []

    var body: some View {
        Section {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                ProtoWorkspaceStatusView(status: status, tooling: settings.protocTooling)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Recompile") { settings.recompileProtos() }
                    .disabled(status == nil || status == .compiling)
            }
            if !warnings.isEmpty {
                ProtoWarningsView(warnings: warnings)
            }
            if settings.hasUnsavedProtoChanges {
                Text("This is the saved definitions' status; your changes compile when you click Done.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Proto Definitions")
        } footer: {
            Text("Shared by every gRPC request in this project that uses project protos.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        Section {
            ForEach(ProtoPathRowID.rows(settings.protoRoots, of: .roots)) { row in
                let index = row.index
                ProtoPathRow(
                    title: settings.describe(settings.protoRoots[index]),
                    sharing: settings.sharing(of: settings.protoRoots[index]),
                    removeLabel: "Remove this proto root"
                ) {
                    settings.removeProtoRoot(at: index)
                }
            }
            Button("Add Folder…") { settings.addProtoRoot() }
        } header: {
            Text("Proto Roots")
        } footer: {
            Text("Folders protoc searches for imports (-I). Compiling them needs protoc.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        Section {
            ForEach(settings.protoEntryFiles) { file in
                HStack {
                    LabeledRow("Entry file") {
                        TextField("Entry file", text: entryFilePath(file), prompt: Text("acme/v1/users.proto"))
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                            .font(.system(.body, design: .monospaced))
                    }
                    Button {
                        settings.removeEntryFile(file.id)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(IconButtonStyle())
                    .help("Remove this entry file")
                    .accessibilityLabel("Remove this entry file")
                }
            }
            Button("Add Entry File") { settings.addEntryFile() }
        } header: {
            Text("Entry Files")
        } footer: {
            Text("Paths relative to a proto root. With none, every .proto file under the roots compiles.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        Section {
            ForEach(ProtoPathRowID.rows(settings.descriptorSets, of: .descriptorSets)) { row in
                let index = row.index
                ProtoPathRow(
                    title: settings.describe(settings.descriptorSets[index]),
                    sharing: settings.sharing(of: settings.descriptorSets[index]),
                    removeLabel: "Remove this descriptor set"
                ) {
                    settings.removeDescriptorSet(at: index)
                }
            }
            Button("Add Descriptor Set…") { settings.addDescriptorSet() }
        } header: {
            Text("Descriptor Sets")
        } footer: {
            Text("Compiled .protoset, .binpb, or .pb files, such as from buf build. They load without protoc.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Keyed by the row's ID rather than `ForEach`'s positional element binding, which would write a removed row's late
    /// commit into its neighbour or trap out of range.
    private func entryFilePath(_ file: ProtoEntryFile) -> Binding<String> {
        Binding(
            get: { settings.protoEntryFiles.first { $0.id == file.id }?.path ?? file.path },
            set: { settings.setEntryFilePath($0, for: file.id) }
        )
    }
}

/// A path row's identity. A grouped `Form` backs all its sections with one list, so two sections keyed by bare
/// indices would share row IDs and draw each other's cards around the wrong rows.
private struct ProtoPathRowID: Hashable, Identifiable {
    enum Kind {
        case roots
        case descriptorSets
    }

    let kind: Kind
    let index: Int

    var id: Self {
        self
    }

    static func rows(_ references: [ProjectPathReference], of kind: Kind) -> [Self] {
        references.indices.map { Self(kind: kind, index: $0) }
    }
}

/// A proto root or descriptor set, with whether its path travels with the project.
private struct ProtoPathRow: View {
    let title: String
    let sharing: PathSharing
    let removeLabel: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .lineLimit(1)
                .truncationMode(.middle)
            PathSharingBadge(sharing: sharing)
            Spacer()
            Button(action: onRemove) {
                Image(systemName: "trash")
            }
            .buttonStyle(IconButtonStyle())
            .help(removeLabel)
            .accessibilityLabel(removeLabel)
        }
    }
}

/// Shared or This Mac, in system colors that carry light and dark variants.
private struct PathSharingBadge: View {
    let sharing: PathSharing
    @Environment(\.appAccent) private var accent

    var body: some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: AppMetrics.badgeCornerRadius).fill(color.opacity(0.15)))
            .help(help)
    }

    private var title: String {
        switch sharing {
        case .shared: "Shared"
        case .thisMacOnly: "This Mac"
        }
    }

    private var color: Color {
        switch sharing {
        case .shared: Color(nsColor: accent)
        case .thisMacOnly: .orange
        }
    }

    private var help: String {
        switch sharing {
        case .shared: "Stored relative to the project, so it works for everyone who has the project."
        case .thisMacOnly: "Remembered on this Mac only and never written to the project."
        }
    }
}

/// The workspace's compile status: compiling, ready, protoc missing (with an install), or what went wrong.
private struct ProtoWorkspaceStatusView: View {
    let status: ProtoWorkspace.Status?
    let tooling: ProtocToolingModel

    var body: some View {
        switch status {
        case nil, .empty?:
            Label("No proto roots or descriptor sets saved", systemImage: "circle.dashed")
                .foregroundStyle(.secondary)
        case .compiling?:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Compiling…")
            }
        case .ready(let serviceCount, let compiledAt)?:
            Label {
                Text("Ready with \(serviceCount) \(serviceCount == 1 ? "service" : "services")")
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            .help("Compiled \(compiledAt.formatted(date: .omitted, time: .standard))")
        case .needsProtoc?:
            VStack(alignment: .leading, spacing: 8) {
                Label("Compiling the proto roots needs protoc. Descriptor sets still load.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                ProtocInstallControl(tooling: tooling, alignment: .leading)
            }
        case .failed(let diagnostics)?:
            ProtoDiagnosticsView(diagnostics: diagnostics)
        case .missingPaths(let paths)?:
            Label("Not found on this Mac: \(paths.joined(separator: ", "))", systemImage: "questionmark.folder")
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}

/// Files the compile skipped while still succeeding, so a schema missing a file says why.
private struct ProtoWarningsView: View {
    let warnings: [ProtocDiagnostic]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(warnings.count == 1 ? "Skipped 1 file" : "Skipped \(warnings.count) files", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(warnings.map(\.description).joined(separator: "\n"))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// protoc's problems as `file:line:column: message`, one selectable block so they copy out together.
private struct ProtoDiagnosticsView: View {
    let diagnostics: [ProtocDiagnostic]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(summary, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
            Text(diagnostics.map(Self.line).joined(separator: "\n"))
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: AppMetrics.containerCornerRadius).fill(Color.secondary.opacity(0.08)))
        }
    }

    private var summary: String {
        let count = diagnostics.count
        return "Compiling failed with \(count) \(count == 1 ? "problem" : "problems")"
    }

    /// protoc's own form, warnings marked as protoc marks them.
    private static func line(_ diagnostic: ProtocDiagnostic) -> String {
        guard diagnostic.severity == .warning else {
            return diagnostic.description
        }
        return ProtocDiagnostic(
            severity: .warning,
            file: diagnostic.file,
            line: diagnostic.line,
            column: diagnostic.column,
            message: "warning: \(diagnostic.message)",
            url: diagnostic.url
        ).description
    }
}
