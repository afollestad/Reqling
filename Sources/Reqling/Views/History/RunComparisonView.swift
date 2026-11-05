import ReqlingKit
import SwiftUI

/// Two runs compared in place of the response pane: what each was, then a unified diff of the section chosen, older
/// lines removed and newer ones added.
struct RunComparisonView: View {
    @Bindable var history: RunHistoryViewModel
    let pair: RunPair
    @Environment(\.calendar) private var calendar
    @Environment(\.timeZone) private var timeZone
    @Environment(\.locale) private var locale

    var body: some View {
        let runs = history.runs
        let older = runs.first { $0.id == pair.older }
        let newer = runs.first { $0.id == pair.newer }
        let formats = RunDateFormats(locale: locale, calendar: calendar, timeZone: timeZone)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.left.arrow.right")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Comparing Runs")
                    .font(.headline)
                Spacer(minLength: 4)
                Button("Done") { history.endComparison() }
                    .controlSize(.small)
            }
            .padding(.horizontal, AppMetrics.detailPaneInset)
            .padding(.vertical, 8)
            Divider()
            if let older, let newer {
                RunComparisonSummary(older: older, newer: newer, formats: formats)
                    .padding(.horizontal, AppMetrics.detailPaneInset)
                    .padding(.vertical, 8)
                Divider()
            }
            RunComparisonContent(history: history)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: pair) {
            await history.loadComparison()
        }
    }
}

/// The two runs a line each, older first, marked as the diff marks their lines; values that differ stand out.
private struct RunComparisonSummary: View {
    let older: RunSummary
    let newer: RunSummary
    let formats: RunDateFormats

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            row(older, marker: "−", color: .red, other: newer)
            row(newer, marker: "+", color: .green, other: older)
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ run: RunSummary, marker: String, color: Color, other: RunSummary) -> some View {
        GridRow {
            Text(marker)
                .font(.callout.monospaced().weight(.bold))
                .foregroundStyle(color)
                .accessibilityLabel(marker == "+" ? "Newer" : "Older")
            Text(formats.stamp(run.startedAt))
                .monospacedDigit()
            RunStatusBadge(status: run.status)
            Text(run.duration.map(ResponseStatusBar.duration) ?? "—")
                .monospacedDigit()
                .fontWeight(run.duration == other.duration ? .regular : .semibold)
            Text(run.responseByteCount.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "—")
                .monospacedDigit()
                .fontWeight(run.responseByteCount == other.responseByteCount ? .regular : .semibold)
            Label(run.environmentName ?? "—", systemImage: "square.stack.3d.up")
                .lineLimit(1)
                .fontWeight(run.environmentName == other.environmentName ? .regular : .semibold)
        }
        .foregroundStyle(.primary)
        .accessibilityElement(children: .combine)
    }
}

/// The section picker over the diff, or why there is nothing to show yet.
private struct RunComparisonContent: View {
    @Bindable var history: RunHistoryViewModel

    var body: some View {
        switch history.comparisonState {
        case .ready(let comparison):
            let section = comparison.sections.first { $0.title == history.comparisonSection } ?? comparison.sections.first
            VStack(alignment: .leading, spacing: AppMetrics.sectionTabsSpacing) {
                SectionPicker(
                    "Compared section",
                    selection: Binding(get: { section?.title ?? "" }, set: { history.comparisonSection = $0 }),
                    options: comparison.sections.map(\.title),
                    label: { $0 }
                )
                if let section {
                    RunComparisonSectionView(section: section, search: history.comparisonSearch)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .padding(.horizontal, AppMetrics.detailPaneInset)
            .padding(.vertical, AppMetrics.paneInset)
        case .missing:
            ContentUnavailableView {
                Label("Run No Longer Kept", systemImage: "clock.badge.xmark")
            } description: {
                Text("The history no longer has one of these runs.")
            } actions: {
                Button("Done") { history.endComparison() }
            }
        case .loading, nil:
            ProgressView("Comparing…")
        }
    }
}

private struct RunComparisonSectionView: View {
    let section: RunComparisonSection
    let search: BodySearchModel

    var body: some View {
        switch section.content {
        case .diff(let diff) where diff.hasChanges:
            VStack(alignment: .leading, spacing: 6) {
                Text(Self.counts(diff))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                CodeViewerPane(document: diff.text, diff: diff.lines, search: search, accessibilityLabel: "\(section.title) differences")
            }
        case .diff:
            ContentUnavailableView(
                "No Differences",
                systemImage: "equal",
                description: Text("Both runs' \(section.title.lowercased()) are the same.")
            )
        case .binary(let identical):
            ContentUnavailableView(
                identical ? "No Differences" : "The Bodies Differ",
                systemImage: identical ? "equal" : "doc.badge.ellipsis",
                description: Text(identical ? "Both runs' binary bodies are the same." : "Binary bodies can't be compared line by line.")
            )
        }
    }

    private static func counts(_ diff: DiffDocument) -> String {
        let added = diff.addedCount == 1 ? "1 line added" : "\(diff.addedCount) lines added"
        let removed = diff.removedCount == 1 ? "1 line removed" : "\(diff.removedCount) lines removed"
        return "\(added), \(removed)"
    }
}
