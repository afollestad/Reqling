import ReqlingKit
import SwiftUI

/// Imports a Postman collection, with any environments and globals, as a new project; once it's written, the same
/// sheet sums up what came over and what needs changes.
struct PostmanImportSheet: View {
    @State var importer: PostmanImportModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            switch importer.phase {
            case .choosing, .importing:
                PostmanImportForm(importer: importer)
                    .disabled(isImporting)
                    .padding(AppMetrics.paneInset)
                SheetFooter(primaryTitle: isImporting ? "Importing…" : "Import", isPrimaryEnabled: importer.canImport) {
                    dismiss()
                } onPrimary: {
                    Task { await importer.startImport() }
                }
            case .finished(let summary):
                PostmanImportSummary(summary: summary)
                    .padding(AppMetrics.paneInset)
                SheetFooter(cancelTitle: nil) {
                    dismiss()
                } onPrimary: {
                    dismiss()
                }
            }
        }
        .frame(width: 520)
    }

    private var isImporting: Bool {
        if case .importing = importer.phase {
            return true
        }
        return false
    }
}

private struct PostmanImportForm: View {
    @Bindable var importer: PostmanImportModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import Postman Collection")
                .font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: 12) {
                LabeledRow("Collection") {
                    HStack {
                        Text(importer.collection?.name ?? "None")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Choose…") {
                            Task { await importer.chooseCollection() }
                        }
                    }
                }
                LabeledRow("Environments") {
                    HStack {
                        Text(importer.variableFiles.isEmpty ? "None" : "")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Add…") {
                            Task { await importer.addVariableFiles() }
                        }
                    }
                }
                if !importer.variableFiles.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(importer.variableFiles) { file in
                            PostmanVariableFileRow(file: file) { importer.removeVariableFile(file.id) }
                        }
                    }
                    .alignedWithLabeledRowControls()
                }
                LabeledRow("Name") {
                    TextField("Name", text: $importer.name, prompt: Text("My API"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                }
                ProjectLocationRow(location: $importer.location, system: importer.app.system)
            }
            if let problem = importer.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("""
                Environments become the project's own, and a globals export joins the Global environment every project \
                shares. Secret values stay in your Keychain.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// One chosen environment or globals file, with a button that takes it out.
private struct PostmanVariableFileRow: View {
    let file: PostmanImportModel.ChosenFile
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: file.isGlobals ? "globe" : "square.stack.3d.up")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(file.name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button(action: onRemove) {
                Image(systemName: "minus")
            }
            .buttonStyle(IconButtonStyle())
            .help("Remove “\(file.name)”")
            .accessibilityLabel("Remove “\(file.name)”")
        }
    }
}
