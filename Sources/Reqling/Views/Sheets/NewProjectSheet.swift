import SwiftUI

struct NewProjectSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var location: URL?

    var body: some View {
        VStack(spacing: 0) {
            form
                .padding(AppMetrics.paneInset)
            SheetFooter(primaryTitle: "Create", isPrimaryEnabled: !trimmedName.isEmpty) {
                dismiss()
            } onPrimary: {
                model.createProject(named: trimmedName, in: location)
                dismiss()
            }
        }
        .frame(width: 460)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespaces)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Project")
                .font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: 12) {
                LabeledRow("Name") {
                    TextField("Name", text: $name, prompt: Text("My API"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                }
                LabeledRow("Location") {
                    HStack {
                        Text(location?.path(percentEncoded: false) ?? "Reqling's projects folder")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Choose…") {
                            location = model.system.chooseDirectory(prompt: "Choose") ?? location
                        }
                    }
                }
            }
            Text("""
                Choose a folder inside your API's repository to share the project, and its environments, through git. \
                Secret values stay in your Keychain.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
