import ReqlingKit
import SwiftUI

/// Imports a Postman collection, with any environments and globals, or an OpenAPI 3 document, from a file or a URL, as
/// a new project; once it's written, the same sheet sums up what came over and what needs changes.
struct ImportSheet: View {
    @State var importer: ImportModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            switch importer.phase {
            case .choosing, .importing:
                ImportForm(importer: importer)
                    .disabled(isImporting)
                    .padding(AppMetrics.paneInset)
                SheetFooter(primaryTitle: isImporting ? "Importing…" : "Import", isPrimaryEnabled: importer.canImport) {
                    dismiss()
                } onPrimary: {
                    Task { await importer.startImport() }
                }
            case .finished(let summary):
                ImportSummary(summary: summary)
                    .padding(AppMetrics.paneInset)
                SheetFooter(cancelTitle: nil) {
                    dismiss()
                } onPrimary: {
                    dismiss()
                }
            }
        }
        .frame(width: 560)
    }

    private var isImporting: Bool {
        if case .importing = importer.phase {
            return true
        }
        return false
    }
}

private struct ImportForm: View {
    @Bindable var importer: ImportModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import")
                .font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: 12) {
                LabeledRow("Source") {
                    HStack {
                        TextField("Source", text: $importer.sourceText, prompt: Text("A URL or a file's path"))
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                            .onSubmit { Task { await importer.load() } }
                        Button("Load") {
                            Task { await importer.load() }
                        }
                        .disabled(!importer.canLoad)
                        Button("Choose…") {
                            Task { await importer.chooseFile() }
                        }
                    }
                }
                ImportSourceStatus(importer: importer)
                    .alignedWithLabeledRowControls()
                if importer.isPostman {
                    ImportVariableFiles(importer: importer)
                }
                LabeledRow("Name") {
                    TextField("Name", text: $importer.name, prompt: Text("My API"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                }
                ProjectLocationRow(location: $importer.location, system: importer.app.system)
            }
            Text("""
                Postman collections, and OpenAPI 3 documents in JSON or YAML. A collection's environments become the \
                project's own, and a globals export joins the Global environment every project shares. Secret values \
                stay in your Keychain.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// What the source holds once loaded, what it refers to that couldn't be loaded, or why it can't be imported.
private struct ImportSourceStatus: View {
    let importer: ImportModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if importer.isLoading {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading…")
                        .foregroundStyle(.secondary)
                }
            } else if let problem = importer.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let found = importer.found {
                Text(found)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            ForEach(importer.loadProblems, id: \.self) { problem in
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A Postman collection's environment and globals exports, added beside it.
private struct ImportVariableFiles: View {
    let importer: ImportModel

    var body: some View {
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
                    ImportVariableFileRow(file: file) { importer.removeVariableFile(file.id) }
                }
            }
            .alignedWithLabeledRowControls()
        }
    }
}

/// One chosen environment or globals file, with a button that takes it out.
private struct ImportVariableFileRow: View {
    let file: ImportModel.ChosenFile
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
