import SwiftUI

/// What a Postman import made: its counts, the environments it changed, and what needs changes, grouped by where it is,
/// as selectable text so it copies out.
struct PostmanImportSummary: View {
    let summary: ProjectImportPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(summary.title)
                .font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: 4) {
                Text(summary.summary)
                ForEach(summary.environments, id: \.self) { line in
                    Text(line)
                        .foregroundStyle(.secondary)
                }
            }
            if summary.groups.isEmpty {
                Label("Nothing needs changes.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                PostmanImportNotes(groups: summary.groups)
            }
            ForEach([summary.credentials, summary.globalProblem, summary.notImported, summary.trust].compactMap(\.self), id: \.self) { text in
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .textSelection(.enabled)
    }
}

/// The notes, by folder, request, environment, or the project, in a scroll that keeps a long list from growing the
/// sheet past the window.
private struct PostmanImportNotes: View {
    let groups: [ProjectImportPresentation.Group]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Needs changes", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.title)
                                .font(.callout.weight(.semibold))
                            ForEach(Array(group.lines.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: 260)
            .background(RoundedRectangle(cornerRadius: AppMetrics.containerCornerRadius).fill(Color.secondary.opacity(0.08)))
        }
    }
}
