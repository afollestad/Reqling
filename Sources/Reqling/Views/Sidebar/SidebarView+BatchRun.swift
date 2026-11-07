import ReqlingKit
import SwiftUI

/// A request's or folder's result in the current or last folder or project run. It reads only its own row's status
/// (`BatchRunner.status(for:)`) and whether a run is going, so a step redraws the badges it changes, not the sidebar.
struct SidebarBatchRunBadge: View {
    let itemID: RequestNodeID
    let isFolder: Bool
    let batches: BatchRunner

    var body: some View {
        if let status = batches.status(for: itemID),
           let badge = BatchBadgePresentation(status, isRunGoing: batches.isRunning, isFolder: isFolder) {
            HStack(spacing: 3) {
                switch badge.symbol {
                case .progress:
                    ProgressView()
                        .controlSize(.mini)
                case .image(let name):
                    Image(systemName: name)
                        .font(.caption)
                        .foregroundStyle(Self.color(badge.tint))
                }
                if let count = badge.count {
                    Text(count)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize()
            .help(badge.description)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Last run: \(badge.description)")
        }
    }

    private static func color(_ tint: BatchBadgePresentation.Tint) -> some ShapeStyle {
        switch tint {
        case .passed: AnyShapeStyle(Color.green)
        case .failed: AnyShapeStyle(Color.red)
        case .secondary: AnyShapeStyle(.secondary)
        case .tertiary: AnyShapeStyle(.tertiary)
        }
    }
}

/// The current or last folder or project run at the sidebar's foot: where it is or how it ended, its counts, and
/// Stop, or Run Again and Dismiss. Shown only while there's a run to report; it alone reads the run, so only it
/// redraws on every step.
struct SidebarBatchRunBar: View {
    let model: AppModel

    var body: some View {
        if model.batches.hasReport, let run = model.batches.run {
            let bar = BatchBarPresentation(run: run, currentName: currentName(of: run))
            VStack(spacing: 0) {
                Divider()
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(bar.title)
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                            .help("\(bar.title) in \(bar.environment)")
                        Text([bar.progress, bar.environment].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text(bar.counts)
                            .font(.caption.monospacedDigit())
                            .lineLimit(1)
                        ForEach(bar.notes, id: \.self) { note in
                            Text(note)
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    Spacer(minLength: 0)
                    SidebarBatchRunActions(model: model, isRunning: bar.isRunning)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .background(.bar)
        }
    }

    /// The running request's name as it is now, so a rename mid-run shows.
    private func currentName(of run: BatchRun) -> String? {
        run.currentRequest.flatMap { model.library.document(run.plan.scope.projectID)?.request($0)?.name }
    }
}

private struct SidebarBatchRunActions: View {
    let model: AppModel
    let isRunning: Bool

    var body: some View {
        HStack(spacing: 2) {
            if isRunning {
                Button {
                    model.stopBatchRun()
                } label: {
                    Image(systemName: "stop.circle")
                }
                .buttonStyle(IconButtonStyle())
                .help("Stop the run")
                .accessibilityLabel("Stop the run")
            } else {
                Button {
                    Task { await model.rerunBatch() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(IconButtonStyle())
                .disabled(model.batches.isRunning)
                .help("Run again")
                .accessibilityLabel("Run again")
                Button {
                    model.dismissBatchRun()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(IconButtonStyle())
                .help("Dismiss the results")
                .accessibilityLabel("Dismiss the results")
            }
        }
    }
}
