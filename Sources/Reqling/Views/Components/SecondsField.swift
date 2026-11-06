import SwiftUI

/// A per-request number of seconds, such as a timeout, that overrides a default or turns something on: typed, or
/// stepped with the arrows, and held to `range`. Empty stands for the default, or off, which `prompt` names; clearing
/// the field is the way back to it.
///
/// A bare `TextField(value:format:)` looked like a text box and stored whatever number was typed, including ones no run
/// can use, such as a negative timeout, which fails the handshake at once.
struct SecondsField: View {
    let title: String
    @Binding var seconds: Double?
    let range: ClosedRange<Double>
    let step: Double
    /// What the empty field stands for, and where either arrow starts from it.
    let start: Double
    /// Shown while empty: the default's value ("Default (30)"), or "Off".
    let prompt: String

    var body: some View {
        HStack(spacing: 6) {
            TextField(
                title,
                value: Binding(get: { seconds }, set: { seconds = Self.typed($0, in: range) }),
                format: .number,
                prompt: Text(prompt)
            )
            .textFieldStyle(.roundedBorder)
            .labelsHidden()
            .frame(width: 110)
            .accessibilityLabel("\(title) in seconds")
            Stepper(
                title,
                value: Binding(
                    get: { seconds ?? start },
                    set: { seconds = Self.stepped(from: seconds, to: $0, start: start, in: range) }
                ),
                in: range,
                step: step
            )
            .labelsHidden()
            .accessibilityLabel(title)
            .accessibilityValue(seconds.map { "\($0.formatted()) seconds" } ?? prompt)
            .help("Change by \(step.formatted()) seconds")
            Text("seconds")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }

    /// A typed value, held to `range`; clearing the field gives `nil`, and so does text the number format reads as
    /// not-a-number, which a project file couldn't store.
    nonisolated static func typed(_ value: Double?, in range: ClosedRange<Double>) -> Double? {
        guard let value, !value.isNaN else {
            return nil
        }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    /// The value after an arrow click. From empty, either arrow gives `start` itself rather than a step past it, so the
    /// first click shows what empty meant instead of jumping from it.
    nonisolated static func stepped(from current: Double?, to value: Double, start: Double, in range: ClosedRange<Double>) -> Double {
        min(max(current == nil ? start : value, range.lowerBound), range.upperBound)
    }
}
