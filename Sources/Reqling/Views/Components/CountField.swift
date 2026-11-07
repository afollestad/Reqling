import SwiftUI

/// A whole number, typed or stepped with the arrows and held to `range`, such as how many times a run repeats.
/// `SecondsField` is its counterpart for a number of seconds that may be left empty.
struct CountField: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    /// What the number counts, shown after it ("times").
    let unit: String

    var body: some View {
        HStack(spacing: 6) {
            TextField(title, value: Binding(get: { value }, set: { value = Self.held($0, in: range) }), format: .number)
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .frame(width: 80)
                .accessibilityLabel(title)
            Stepper(title, value: $value, in: range)
                .labelsHidden()
                .accessibilityLabel(title)
                .accessibilityValue("\(value) \(unit)")
                .help("Change by 1")
            Text(unit)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }

    nonisolated static func held(_ value: Int, in range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
