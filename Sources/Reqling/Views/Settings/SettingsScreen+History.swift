import ReqlingKit
import SwiftUI

/// How long and how much of each request's run history stays on this Mac, how much it takes now, and clearing all of
/// it.
struct HistorySettingsPage: View {
    let model: AppModel

    var body: some View {
        let settings = model.settings.settings
        SettingsFormSection("Kept Runs") {
            SettingsFormRow {
                SettingsResponsiveControlRow(
                    "Keep runs for",
                    helpText: "Each request's latest run stays until the size limit needs its space.",
                    horizontalControlSizing: .intrinsic
                ) {
                    SettingsMenuPicker(
                        "Keep runs for",
                        selection: Binding(get: { settings.historyRetention }, set: { model.setHistoryRetention($0) }),
                        options: HistoryRetention.allCases,
                        label: Self.title
                    )
                }
            }
            SettingsFormRow {
                SettingsResponsiveControlRow(
                    "Size limit",
                    helpText: "Once every request's runs together pass it, the oldest go first.",
                    horizontalControlSizing: .intrinsic
                ) {
                    SettingsMenuPicker(
                        "Size limit",
                        selection: Binding(get: { settings.historySizeLimit }, set: { model.setHistorySizeLimit($0) }),
                        options: HistorySizeLimit.allCases,
                        label: Self.title
                    )
                }
            }
            SettingsFormRow(showsDivider: false) {
                SettingsResponsiveControlRow("Stored") {
                    HStack(spacing: 10) {
                        Spacer()
                        Text(Self.storedText(model.runner.history.storedBytes))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Button("Clear All History…") { model.historyClearPending = .all }
                    }
                }
            }
        }
    }

    static func title(for retention: HistoryRetention) -> String {
        switch retention {
        case .day: "1 Day"
        case .week: "1 Week"
        case .month: "30 Days"
        case .quarter: "90 Days"
        case .forever: "Forever"
        }
    }

    static func title(for limit: HistorySizeLimit) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(limit.bytes), countStyle: .file)
    }

    /// `nil` until pruning first weighs the history, moments after launch.
    static func storedText(_ bytes: Int?) -> String {
        bytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "—"
    }
}
