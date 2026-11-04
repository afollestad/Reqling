import SwiftUI

/// A label in a fixed column with its control after it, starting at the leading edge, so labels and fields line up
/// across every form in the app.
struct LabeledRow<Control: View>: View {
    let title: String
    private let control: Control

    init(_ title: String, @ViewBuilder control: () -> Control) {
        self.title = title
        self.control = control()
    }

    var body: some View {
        HStack(spacing: AppMetrics.labelSpacing) {
            Text(title)
                .frame(width: AppMetrics.labelWidth, alignment: .leading)
            control
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Secondary text that belongs to the `LabeledRow` above it.
struct LabeledRowNote: View {
    let text: String

    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .alignedWithLabeledRowControls()
    }
}

extension View {
    /// Indents to a `LabeledRow`'s control column.
    func alignedWithLabeledRowControls() -> some View {
        padding(.leading, AppMetrics.labelWidth + AppMetrics.labelSpacing)
    }
}
