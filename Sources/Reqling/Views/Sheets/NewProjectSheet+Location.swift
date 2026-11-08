import SwiftUI

/// Where a new project's folder goes: Reqling's projects folder unless the person chooses another, such as a folder in
/// their API's repository. New Project and the Postman import share it.
struct ProjectLocationRow: View {
    @Binding var location: URL?
    let system: any SystemIntegration

    var body: some View {
        LabeledRow("Location") {
            HStack {
                Text(location?.abbreviatedPath ?? "Reqling's projects folder")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Choose…") {
                    location = system.chooseDirectory(prompt: "Choose") ?? location
                }
            }
        }
    }
}
