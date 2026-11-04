import ReqlingKit
import SwiftUI

struct InterfaceSettingsPage: View {
    let settings: SettingsStore

    var body: some View {
        SettingsFormSection("Appearance") {
            SettingsFormRow(showsDivider: false) {
                SettingsResponsiveControlRow("Theme", helpText: "System follows your Mac's appearance.", horizontalControlSizing: .intrinsic) {
                    SettingsMenuPicker(
                        "Theme",
                        selection: Binding(get: { settings.settings.theme }, set: { theme in settings.update { $0.theme = theme } }),
                        options: AppTheme.allCases,
                        label: Self.title
                    )
                }
            }
        }
    }

    static func title(for theme: AppTheme) -> String {
        switch theme {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

struct RequestsSettingsPage: View {
    let settings: SettingsStore

    var body: some View {
        SettingsFormSection("Defaults") {
            SettingsFormRow {
                SettingsResponsiveControlRow(
                    "Timeout",
                    helpText: Self.timeoutHelp,
                    horizontalControlSizing: .intrinsic
                ) {
                    Stepper(value: timeout, in: AppSettings.timeoutRange, step: 5) {
                        Text("\(Int(settings.settings.requestTimeoutSeconds)) seconds")
                            .monospacedDigit()
                    }
                }
            }
            SettingsToggleRow(
                "Follow redirects",
                helpText: "Requests follow 3xx responses unless their own options say otherwise.",
                isOn: Binding(get: { settings.settings.followRedirects }, set: { value in settings.update { $0.followRedirects = value } })
            )
            SettingsToggleRow(
                "Verify TLS certificates",
                helpText: "Turn off only to debug a server with a broken certificate; a project's CA certificates are usually the better fix.",
                isOn: Binding(get: { settings.settings.verifyTLS }, set: { value in settings.update { $0.verifyTLS = value } }),
                showsDivider: false
            )
        }
    }

    private static let timeoutHelp =
        "How long a request may take, \(Int(AppSettings.timeoutRange.lowerBound))–\(Int(AppSettings.timeoutRange.upperBound)) seconds."

    private var timeout: Binding<Double> {
        Binding(get: { settings.settings.requestTimeoutSeconds }, set: { value in settings.update { $0.requestTimeoutSeconds = value } })
    }
}
