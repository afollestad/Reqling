import SwiftUI

/// "2 problems" beside an editor: each one, chosen, selects what it marks. The underlines are only drawn; this lists
/// the same problems for keyboard and VoiceOver users.
struct CodeProblemsMenu: View {
    let diagnostics: [CodeDiagnostic]
    let handle: CodeEditorHandle
    /// What the problems are in, for the help text: "the query".
    let subject: String

    var body: some View {
        let errors = diagnostics.filter { $0.severity == .error }.count
        let title = "\(diagnostics.count) problem\(diagnostics.count == 1 ? "" : "s")"
        Menu {
            ForEach(Array(diagnostics.enumerated()), id: \.offset) { _, diagnostic in
                Button(diagnostic.message) {
                    handle.reveal(diagnostic.range)
                }
            }
        } label: {
            Label(title, systemImage: errors > 0 ? "xmark.octagon" : "exclamationmark.triangle")
        }
        .controlSize(.small)
        .fixedSize()
        .help("Show a problem in \(subject)")
        .accessibilityLabel(title)
    }
}
