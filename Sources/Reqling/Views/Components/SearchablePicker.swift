import SwiftUI

/// A picker whose popover filters its options as you type, for lists too long to scan in a menu, such as a server's
/// services and methods.
///
/// The button shows `selection` as typed even when no option matches it, so a saved choice the loaded options lack
/// (a schema that failed to load, a method since removed) stays visible instead of reading as empty.
struct SearchablePicker<Option: Hashable>: View {
    /// Names the picker for VoiceOver and its tooltip, such as "Service".
    let title: String
    let selection: String
    var placeholder = "Choose…"
    /// Shown in the popover when there is nothing to pick.
    var emptyMessage = "Nothing to choose from."
    let options: [Option]
    let label: (Option) -> String
    var detail: ((Option) -> String?)?
    let onSelect: (Option) -> Void

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            HStack(spacing: 4) {
                Text(selection.isEmpty ? placeholder : selection)
                    .foregroundStyle(selection.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .help(title)
        .accessibilityLabel(title)
        .accessibilityValue(selection.isEmpty ? placeholder : selection)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            SearchablePickerList(
                title: title,
                selection: selection,
                emptyMessage: emptyMessage,
                options: options,
                label: label,
                detail: detail
            ) { option in
                isPresented = false
                onSelect(option)
            }
        }
    }
}

/// The popover: a filter field, focused on open, over the matching options. ↑ and ↓ move the highlight and Return
/// picks it. The keys are handled on the field itself: the popover is its own key window, so nothing else competes
/// for them.
private struct SearchablePickerList<Option: Hashable>: View {
    let title: String
    let selection: String
    let emptyMessage: String
    let options: [Option]
    let label: (Option) -> String
    let detail: ((Option) -> String?)?
    let onSelect: (Option) -> Void

    @State private var query = ""
    /// The match the arrow keys moved to, by position; `nil` follows `SearchablePickerFilter.preferred`.
    @State private var highlighted: Int?
    @FocusState private var isFilterFocused: Bool

    var body: some View {
        let labels = options.map(label)
        let matches = SearchablePickerFilter.matches(labels, query: query).map { options[$0] }
        let current = highlighted ?? SearchablePickerFilter.preferred(in: matches.map(label), query: query, selection: selection)
        VStack(spacing: 0) {
            filterField(matches: matches, current: current)
            Divider()
            if matches.isEmpty {
                Text(options.isEmpty ? emptyMessage : "No matches.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(matches.enumerated()), id: \.element) { position, option in
                                SearchablePickerRow(
                                    title: label(option),
                                    detail: detail?(option) ?? nil,
                                    isSelected: label(option) == selection,
                                    isHighlighted: position == current
                                ) {
                                    onSelect(option)
                                }
                                .id(option)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(maxHeight: 300)
                    .onChange(of: current, initial: true) { _, position in
                        if matches.indices.contains(position) {
                            proxy.scrollTo(matches[position])
                        }
                    }
                }
            }
        }
        .frame(width: 340)
        .onAppear { isFilterFocused = true }
    }

    private func filterField(matches: [Option], current: Int) -> some View {
        TextField("Filter", text: $query, prompt: Text("Filter"))
            .textFieldStyle(.roundedBorder)
            .focused($isFilterFocused)
            .accessibilityLabel("Filter \(title.lowercased())s")
            .onChange(of: query) { _, _ in
                highlighted = nil
            }
            .onKeyPress(.downArrow) {
                highlighted = SearchablePickerFilter.moved(current, by: 1, count: matches.count)
                return .handled
            }
            .onKeyPress(.upArrow) {
                highlighted = SearchablePickerFilter.moved(current, by: -1, count: matches.count)
                return .handled
            }
            .onSubmit {
                if matches.indices.contains(current) {
                    onSelect(matches[current])
                }
            }
            .padding(8)
    }
}

/// What a `SearchablePicker`'s filter shows and which match Return picks, apart from the view so it can be tested.
enum SearchablePickerFilter {
    /// The positions of `labels` containing `query`, in order; all of them for a blank query.
    static func matches(_ labels: [String], query: String) -> [Int] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            return Array(labels.indices)
        }
        return labels.indices.filter { labels[$0].localizedStandardContains(trimmed) }
    }

    /// Where the highlight starts among `matchLabels`: an exact match (ignoring case), so typing a whole name picks
    /// it even when a longer one containing it is declared first; else the current selection while the query is
    /// blank; else the first match.
    static func preferred(in matchLabels: [String], query: String, selection: String) -> Int {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let target = trimmed.isEmpty ? selection : trimmed
        return matchLabels.firstIndex { $0.caseInsensitiveCompare(target) == .orderedSame } ?? 0
    }

    /// One step up or down, stopping at either end.
    static func moved(_ position: Int, by step: Int, count: Int) -> Int {
        guard count > 0 else {
            return 0
        }
        return min(max(position + step, 0), count - 1)
    }
}

private struct SearchablePickerRow: View {
    let title: String
    let detail: String?
    let isSelected: Bool
    /// Where ↑, ↓, and Return act.
    let isHighlighted: Bool
    let action: () -> Void
    @Environment(\.appAccent) private var accent

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.semibold))
                    .opacity(isSelected ? 1 : 0)
                    .accessibilityHidden(true)
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: AppMetrics.badgeCornerRadius, style: .continuous)
                    .fill(isHighlighted ? Color(nsColor: accent).opacity(0.22) : isHovered ? Color(nsColor: accent).opacity(0.12) : Color.clear)
                    .padding(.horizontal, 4)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
