import SwiftUI

/// Shared sizes for the settings form.
enum SettingsScreenLayout {
    static let settingsRowHeight: CGFloat = 32
    static let settingsControlWidthFraction: CGFloat = 0.5
    static let settingsMinimumHorizontalControlWidth: CGFloat = 180
    static let settingsResponsiveRowSpacing: CGFloat = 12
    static let settingsResponsiveStackedSpacing: CGFloat = 8
    static let settingsRowHorizontalPadding: CGFloat = 20
    static let settingsRowVerticalPadding: CGFloat = 12
    static let settingsRowPressedOpacity: CGFloat = 0.03
    static let settingsControlSurfaceHeight: CGFloat = 36
    static let settingsPickerWidth: CGFloat = 150
    /// Inset shared by the detail column and the compact navigation strip's leading edge, so
    /// the first chip and the header title below it cannot drift apart.
    static let settingsContentInset = AppMetrics.screenInset
    static let settingsSectionCornerRadius: CGFloat = 18
    /// The menu picker's surface: a control inside a card, so smaller than the card's own radius.
    static let settingsControlCornerRadius: CGFloat = 8
    static let settingsSectionSpacing: CGFloat = 28
    static let settingsSectionHeaderSpacing: CGFloat = 10
}

struct SettingsFormSection<Content: View>: View {
    let title: String
    private let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsScreenLayout.settingsSectionHeaderSpacing) {
            SettingsFormSectionHeader(title)

            VStack(spacing: 0) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: SettingsScreenLayout.settingsSectionCornerRadius, style: .continuous)
                    .fill(Color.secondary.opacity(0.08))
            )
            .clipShape(RoundedRectangle(cornerRadius: SettingsScreenLayout.settingsSectionCornerRadius, style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SettingsFormSectionHeader: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .accessibilityAddTraits(.isHeader)
    }
}

struct SettingsFormRow<Content: View>: View {
    private let showsDivider: Bool
    private let content: Content

    init(
        showsDivider: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        self.showsDivider = showsDivider
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, minHeight: SettingsScreenLayout.settingsRowHeight, alignment: .leading)
            .padding(.horizontal, SettingsScreenLayout.settingsRowHorizontalPadding)
            .padding(.vertical, SettingsScreenLayout.settingsRowVerticalPadding)
            .overlay(alignment: .bottom) {
                if showsDivider {
                    Divider()
                        .padding(.horizontal, SettingsScreenLayout.settingsRowHorizontalPadding)
                }
            }
    }
}

struct SettingsToggleRow: View {
    let title: String
    private let helpText: String?
    private let showsDivider: Bool

    @Binding private var isOn: Bool

    init(
        _ title: String,
        helpText: String? = nil,
        isOn: Binding<Bool>,
        showsDivider: Bool = true
    ) {
        self.title = title
        self.helpText = helpText
        _isOn = isOn
        self.showsDivider = showsDivider
    }

    var body: some View {
        SettingsToggleControl(title, helpText: helpText, isOn: $isOn) { indicator in
            SettingsFormRow(showsDivider: showsDivider) {
                SettingsResponsiveControlRow(title, helpText: helpText, horizontalControlSizing: .intrinsicInline) {
                    indicator
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
    }
}
