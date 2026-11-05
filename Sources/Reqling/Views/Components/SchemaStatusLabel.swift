import SwiftUI

/// How the last schema load went, on one line, with the full text as its tooltip: the gRPC and GraphQL editors'
/// Schema rows.
struct SchemaStatusLabel: View {
    enum State: Equatable {
        case loading
        /// Nothing can load yet; the text says what is missing.
        case idle(String)
        /// `summary` says what loaded; `issue` why it may be stale or partial.
        case ready(String, issue: String?)
        case failed(String)
    }

    let state: State

    var body: some View {
        switch state {
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
        case .ready(let summary, let issue?):
            line("\(summary). \(issue)", systemImage: "exclamationmark.triangle.fill", tint: .orange)
        case .ready(let summary, nil):
            line(summary, systemImage: "checkmark.circle.fill", tint: .green)
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
}
