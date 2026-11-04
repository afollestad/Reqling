import SwiftUI

/// A failure shown in a settings row, sized like the row's other values so every page reads the same.
struct SettingsErrorLabel: View {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var body: some View {
        Label(message, systemImage: "xmark.octagon")
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}
