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
                    SchemaStatusLabel(state: GRPCSchemaStatus.state(schema.status, serviceCount: schema.services.count))
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

/// The gRPC schema loader's status as the Schema row shows it.
private enum GRPCSchemaStatus {
    static func state(_ status: GRPCSchemaLoader.Status, serviceCount: Int) -> SchemaStatusLabel.State {
        switch status {
        case .loading: .loading
        case .idle(let message): .idle(message)
        case .ready(let source, let issue): .ready(summary(source, serviceCount: serviceCount), issue: issue)
        case .failed(let message): .failed(message)
        }
    }

    private static func summary(_ source: GRPCSchema.Source, serviceCount: Int) -> String {
        let services = "\(serviceCount) service\(serviceCount == 1 ? "" : "s")"
        return switch source {
        case .projectProtos: "\(services) from the project's protos"
        case .reflection: "\(services) from server reflection"
        case .descriptorSet: "\(services) from the descriptor set"
        }
    }
}
