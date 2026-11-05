import ReqlingKit
import SwiftUI

/// Under a response pane's status bar while it shows a past run instead of the latest: which run, and sending it again,
/// putting its request back in the editor, or returning to the latest.
struct PinnedRunBar: View {
    let history: RunHistoryViewModel
    @Environment(\.calendar) private var calendar
    @Environment(\.timeZone) private var timeZone
    @Environment(\.locale) private var locale

    var body: some View {
        if let run = history.pinnedRun {
            let stamp = RunDateFormats(locale: locale, calendar: calendar, timeZone: timeZone).stamp(run.startedAt)
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text("Run from \(stamp)")
                        .font(.callout)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Button {
                        history.rerun(run)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(IconButtonStyle())
                    .disabled(!history.canReplay(run))
                    .help("Re-run")
                    .accessibilityLabel("Re-run")
                    Button {
                        history.requestRestore(run)
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .buttonStyle(IconButtonStyle())
                    .disabled(!history.canRestore(run))
                    .help("Restore Request")
                    .accessibilityLabel("Restore Request")
                    Button("Show Latest") { history.showLatest() }
                        .controlSize(.small)
                }
                .padding(.horizontal, AppMetrics.detailPaneInset)
                .padding(.vertical, 4)
            }
        }
    }
}

/// The run history's confirmations, on the editor screen so the inspector and `PinnedRunBar` share one.
struct RunHistoryPresentations: ViewModifier {
    let history: RunHistoryViewModel

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Restore the request as this run sent it?",
            isPresented: Binding(get: { history.restorePending != nil }, set: { if !$0 { history.restorePending = nil } }),
            titleVisibility: .visible,
            // The action takes the run from here: dismissal may clear `restorePending` first.
            presenting: history.restorePending
        ) { pending in
            Button("Restore") { history.confirmRestore(pending) }
        } message: { _ in
            Text("What the editor holds now is replaced and saved.")
        }
    }
}

/// The response pane's content while it waits on a past run, or finds it gone.
struct PinnedRunPlaceholder: View {
    let status: PinnedRunStatus
    let history: RunHistoryViewModel

    var body: some View {
        switch status {
        case .loading:
            ProgressView()
                .accessibilityLabel("Loading the run")
        case .missing:
            ContentUnavailableView {
                Label("Run No Longer Kept", systemImage: "clock.badge.xmark")
            } description: {
                Text("The history no longer has this run.")
            } actions: {
                Button("Show Latest") { history.showLatest() }
            }
        }
    }
}
