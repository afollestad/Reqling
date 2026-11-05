import ReqlingKit
import SwiftUI

/// The selected request's runs, newest first and grouped by day, in the window's inspector column. Selecting one shows
/// it in the response pane; selecting two and choosing Compare compares them there.
struct RunHistoryInspector: View {
    @Bindable var history: RunHistoryViewModel
    @Environment(\.calendar) private var calendar
    @Environment(\.timeZone) private var timeZone
    @Environment(\.locale) private var locale
    /// What Today and Yesterday are relative to, moved whenever the calendar day changes (midnight, waking past it, or a
    /// new time zone): nothing else re-renders an idle inspector, so its titles would name the day before.
    @State private var now = Date()

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
                // AppKit, not a SwiftUI `List`, to keep the selection neutral while the list has focus; see `RunHistoryTable`.
                RunHistoryTable(
                    history: history,
                    days: history.days(formats: formats, now: now),
                    latest: runs.first?.id,
                    selection: history.displayedSelection
                )
                RunHistoryFooter(history: history)
            }
        }
        .onChange(of: runs.map(\.id)) { _, listed in
            history.retainSelection(in: listed)
        }
        .task {
            for await _ in NotificationCenter.default.notifications(named: .NSCalendarDayChanged) {
                now = Date()
            }
        }
    }

    private var formats: RunDateFormats {
        RunDateFormats(locale: locale, calendar: calendar, timeZone: timeZone)
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
