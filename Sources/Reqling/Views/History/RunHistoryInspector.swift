import ReqlingKit
import SwiftUI

/// The selected request's runs, newest first and grouped by day, in the window's inspector column. Selecting one shows
/// it in the response pane; selecting two and choosing Compare compares them there.
struct RunHistoryInspector: View {
    @Bindable var history: RunHistoryViewModel
    @Environment(\.calendar) private var calendar
    @Environment(\.timeZone) private var timeZone
    @Environment(\.locale) private var locale

    var body: some View {
        let runs = history.runs
        VStack(spacing: 0) {
            if runs.isEmpty {
                CompactEmptyState(
                    systemImage: "clock",
                    title: "No Runs Yet",
                    message: "Each time this request is sent, the run is kept here."
                ) {
                    EmptyView()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                RunHistoryList(history: history, days: history.days(formats: formats), latest: runs.first?.id)
                RunHistoryFooter(history: history)
            }
        }
        .onChange(of: runs.map(\.id)) { _, listed in
            history.retainSelection(in: listed)
        }
    }

    private var formats: RunDateFormats {
        RunDateFormats(locale: locale, calendar: calendar, timeZone: timeZone)
    }
}

private struct RunHistoryList: View {
    @Bindable var history: RunHistoryViewModel
    let days: [RunHistoryDay]
    let latest: RunID?

    var body: some View {
        List(selection: $history.selection) {
            ForEach(days) { day in
                Section(day.title) {
                    ForEach(day.runs) { row in
                        RunHistoryRow(run: row.run, time: row.time, isLatest: row.run.id == latest)
                            .equatable()
                            .tag(row.run.id)
                    }
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: RunID.self) { runs in
            RunHistoryMenu(history: history, selected: runs)
        }
        .accessibilityLabel("Run history")
    }
}

/// What can be done with the runs a context menu was opened on.
private struct RunHistoryMenu: View {
    let history: RunHistoryViewModel
    let selected: Set<RunID>

    var body: some View {
        let runs = history.runs.filter { selected.contains($0.id) }
        if runs.count == 1, let run = runs.first {
            Button("Re-run") { history.rerun(run) }
                .disabled(!history.canReplay(run))
            Button("Restore Request…") { history.requestRestore(run) }
                .disabled(!history.canRestore(run))
            Divider()
            Button("Compare with Latest") { history.compareWithLatest(run.id) }
                .disabled(run.id == history.runs.first?.id)
        } else if runs.count == 2 {
            Button("Compare") {
                history.selection = selected
                history.compare()
            }
        }
    }
}

private struct RunHistoryFooter: View {
    let history: RunHistoryViewModel

    var body: some View {
        HStack(spacing: 6) {
            Button {
                history.compare()
            } label: {
                Label("Compare", systemImage: "arrow.left.arrow.right")
            }
            .buttonStyle(.borderless)
            .disabled(!history.canCompare)
            .help("Compare the two selected runs")
            Spacer()
            Menu {
                Button("Clear History…", role: .destructive) { history.requestClear() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("More history actions")
            .accessibilityLabel("More history actions")
            .iconButtonChrome()
        }
        .padding(.horizontal, 12)
        // The menu's icon tile carries its own padding, so the bar's vertical inset is that much smaller.
        .padding(.top, 9)
        .padding(.bottom, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}
