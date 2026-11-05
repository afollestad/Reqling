import SwiftUI

/// Select All · Select None above a table of per-row checkboxes, in the accent so they read as links rather than as
/// another row's controls. Each dims when it would change nothing.
struct CheckboxSelectionBar<Row: Identifiable & Equatable>: View {
    @Binding var rows: [Row]
    let isOn: WritableKeyPath<Row, Bool>

    var body: some View {
        HStack(spacing: 6) {
            CheckboxSelectionLink(title: "Select All", isActionable: rows.contains { !$0[keyPath: isOn] }) { setAll(true) }
            Text("·")
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            CheckboxSelectionLink(title: "Select None", isActionable: rows.contains { $0[keyPath: isOn] }) { setAll(false) }
        }
        .font(.callout)
    }

    private func setAll(_ value: Bool) {
        var updated = rows
        for index in updated.indices {
            updated[index][keyPath: isOn] = value
        }
        rows = updated
    }
}

private struct CheckboxSelectionLink: View {
    let title: String
    let isActionable: Bool
    let action: () -> Void
    @Environment(\.appAccent) private var accent
    /// The table's own enabled state, such as a read-only request's, read before this link disables itself.
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(title, action: action)
            .buttonStyle(.borderless)
            .foregroundStyle(isActionable && isEnabled ? AnyShapeStyle(Color(nsColor: accent)) : AnyShapeStyle(.tertiary))
            .disabled(!isActionable)
    }
}
