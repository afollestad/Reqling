import SwiftUI

/// The in-place search above a body: its field, where the current match stands, and stepping between matches.
/// Return and the Find menu step forward, Shift-Return back, and Escape closes it.
struct BodySearchBar: View {
    @Bindable var search: BodySearchModel
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Find", text: $search.query)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .onSubmit { search.next() }
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.shift) else {
                        return .ignored
                    }
                    search.previous()
                    return .handled
                }
                .onExitCommand { search.dismiss() }
                .accessibilityLabel("Find")
            Text(search.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .accessibilityLabel(search.status)
            HStack(spacing: 2) {
                Button {
                    search.previous()
                } label: {
                    Image(systemName: "chevron.up")
                }
                .help("Previous match")
                .accessibilityLabel("Previous match")
                Button {
                    search.next()
                } label: {
                    Image(systemName: "chevron.down")
                }
                .help("Next match")
                .accessibilityLabel("Next match")
            }
            .buttonStyle(IconButtonStyle())
            Button("Done") { search.dismiss() }
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: AppMetrics.inputCornerRadius, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: AppMetrics.inputCornerRadius, style: .continuous).strokeBorder(Color(nsColor: .separatorColor)))
        .focusedValue(\.bodySearch, search)
        .onChange(of: search.focusRequest, initial: true) {
            isFocused = true
        }
        .onChange(of: search.status) { _, status in
            if !status.isEmpty {
                AccessibilityNotification.Announcement(status).post()
            }
        }
    }
}
