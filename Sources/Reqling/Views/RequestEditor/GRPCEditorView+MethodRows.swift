import ReqlingKit
import SwiftUI

/// The service and method to call, and where their schema comes from.
struct GRPCMethodRows: View {
    let editor: GRPCEditorViewModel

    var body: some View {
        let schema = editor.schema
        VStack(alignment: .leading, spacing: 8) {
            LabeledRow("Method") {
                HStack(spacing: 6) {
                    SearchablePicker(
                        title: "Service",
                        selection: editor.spec.service,
                        placeholder: "Service",
                        emptyMessage: "No services yet: the schema hasn't loaded.",
                        options: schema.services,
                        label: \.fullName,
                        detail: { "\($0.methods.count) method\($0.methods.count == 1 ? "" : "s")" },
                        onSelect: { editor.select($0) }
                    )
                    Text("/")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    SearchablePicker(
                        title: "Method",
                        selection: editor.spec.method,
                        placeholder: "Method",
                        emptyMessage: editor.spec.service.isEmpty ? "Choose a service first." : "This service has no methods in the schema.",
                        options: editor.methods,
                        label: \.name,
                        detail: { GRPCMethodKindBadge.title(for: $0.kind) },
                        onSelect: { editor.select($0) }
                    )
                    if let kind = editor.selectedMethod?.kind {
                        GRPCMethodKindBadge(kind: kind)
                    }
                }
            }
            LabeledRow("Schema") {
                HStack(spacing: 8) {
                    GRPCSchemaSourceMenu(editor: editor)
                    GRPCSchemaStatusLabel(status: schema.status, serviceCount: schema.services.count)
                    Spacer(minLength: 0)
                    Button {
                        editor.refreshSchema()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(IconButtonStyle())
                    .help("Reload the schema, asking the server again for reflection")
                    .accessibilityLabel("Reload the schema")
                    Button("Configure Protos…") { editor.configureProtos() }
                        .fixedSize()
                        .help("Choose the project's proto files and descriptor sets in Project Settings")
                }
            }
        }
    }
}

/// Automatic, the project's protos, server reflection, or one descriptor set file.
private struct GRPCSchemaSourceMenu: View {
    let editor: GRPCEditorViewModel

    var body: some View {
        let title = editor.schemaSourceTitle
        Menu {
            choice("Automatic", .automatic)
            choice("Project Protos", .projectProtos)
            choice("Server Reflection", .reflection)
            Divider()
            if case .descriptorSet = editor.spec.schema {
                Label(title, systemImage: "checkmark")
                Button("Choose Another Descriptor Set…") { editor.chooseDescriptorSet() }
            } else {
                Button("Descriptor Set…") { editor.chooseDescriptorSet() }
            }
        } label: {
            Text(title)
        }
        .fixedSize()
        .help("Where the services and messages come from. Automatic uses the project's protos when it has any, else reflection.")
        .accessibilityLabel("Schema source")
        .accessibilityValue(title)
    }

    private func choice(_ title: String, _ source: GRPCSchemaSource) -> some View {
        Button {
            editor.setSchemaSource(source)
        } label: {
            if editor.spec.schema == source {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }
}

/// How the last schema load went, on one line; the full text is the tooltip.
private struct GRPCSchemaStatusLabel: View {
    let status: GRPCSchemaLoader.Status
    let serviceCount: Int

    var body: some View {
        switch status {
        case .loading:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading the schema…")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        case .idle(let message):
            line(message, systemImage: "info.circle", tint: .secondary)
        case .ready(let source, let issue?):
            line("\(summary(source)). \(issue)", systemImage: "exclamationmark.triangle.fill", tint: .orange)
        case .ready(let source, nil):
            line(summary(source), systemImage: "checkmark.circle.fill", tint: .green)
        case .failed(let message):
            line(message, systemImage: "xmark.octagon.fill", tint: .red)
        }
    }

    private func line(_ text: String, systemImage: String, tint: Color) -> some View {
        Label {
            Text(text)
                .lineLimit(1)
                .truncationMode(.tail)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .help(text)
    }

    private func summary(_ source: GRPCSchema.Source) -> String {
        let services = "\(serviceCount) service\(serviceCount == 1 ? "" : "s")"
        return switch source {
        case .projectProtos: "\(services) from the project's protos"
        case .reflection: "\(services) from server reflection"
        case .descriptorSet: "\(services) from the descriptor set"
        }
    }
}
