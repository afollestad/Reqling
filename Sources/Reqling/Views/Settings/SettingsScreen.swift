import ReqlingKit
import SwiftUI

/// Settings, shown in the main window's detail area. Wide panes list the pages on the side; narrow ones switch to a
/// scrolling chip strip so every page stays reachable.
struct SettingsScreen: View {
    private static let sidebarLayoutMinimumWidth: CGFloat = 640
    private static let sidebarWidth: CGFloat = 180

    @Bindable var model: AppModel

    var body: some View {
        // Read above the GeometryReader, whose closure re-runs on every frame of a resize.
        let page = model.settingsPage
        GeometryReader { proxy in
            if proxy.size.width >= Self.sidebarLayoutMinimumWidth {
                HStack(spacing: 0) {
                    SettingsSideList(selection: $model.settingsPage)
                        .frame(width: Self.sidebarWidth)
                    Divider()
                    SettingsDetail(model: model)
                }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    SettingsScreenCompactNavigation(selection: page) { model.settingsPage = $0 }
                        .equatable()
                        .padding(.top, 20)
                        .padding(.bottom, 4)
                    SettingsDetail(model: model)
                }
            }
        }
    }
}

private struct SettingsSideList: View {
    @Binding var selection: SettingsPage

    var body: some View {
        List(selection: Binding(get: { Optional(selection) }, set: { if let page = $0 { selection = page } })) {
            ForEach(SettingsPage.allCases) { page in
                Label(page.title, systemImage: page.systemImage)
                    .padding(.vertical, 4)
                    .tag(page)
            }
        }
        .listStyle(.sidebar)
    }
}

private struct SettingsDetail: View {
    let model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsScreenLayout.settingsSectionSpacing) {
                SettingsScreenHeader(page: model.settingsPage) { model.closeSettings() }
                switch model.settingsPage {
                case .updates:
                    AppUpdatesSettingsPage(model: model)
                case .grpc:
                    GRPCSettingsPage(settings: model.settings, tooling: model.protocTooling)
                case .interface:
                    InterfaceSettingsPage(settings: model.settings)
                case .mcp:
                    MCPSettingsPage(model: model.mcpSettings)
                case .requests:
                    RequestsSettingsPage(settings: model.settings)
                }
            }
            .padding(SettingsScreenLayout.settingsContentInset)
            .frame(maxWidth: 760, alignment: .leading)
        }
    }
}

struct SettingsScreenHeader: View {
    let page: SettingsPage
    let onClose: () -> Void

    var body: some View {
        ScreenHeader(page.title, subtitle: page.description) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.cancelAction)
            .help("Close Settings")
            .accessibilityLabel("Close Settings")
        }
    }
}

/// The page strip for panes too narrow for the side list. It scrolls rather than clips, and scrolls the selection
/// into view, so no page is ever cut off.
struct SettingsScreenCompactNavigation: View, Equatable {
    let selection: SettingsPage
    let onSelect: (SettingsPage) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(SettingsPage.allCases) { page in
                        Button(page.title) { onSelect(page) }
                            .buttonStyle(SettingsChipStyle(isSelected: page == selection))
                            .id(page)
                            .accessibilityAddTraits(page == selection ? .isSelected : [])
                    }
                }
                .padding(.horizontal, SettingsScreenLayout.settingsContentInset)
            }
            .onChange(of: selection, initial: true) { _, page in
                proxy.scrollTo(page)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings section")
    }

    /// Excludes `onSelect`, which only writes `AppModel.settingsPage`; `selection` covers everything rendered.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.selection == rhs.selection
    }
}

private struct SettingsChipStyle: ButtonStyle {
    let isSelected: Bool
    @Environment(\.appAccent) private var accent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(
                isSelected ? Color(nsColor: accent).opacity(0.22) : Color.secondary.opacity(configuration.isPressed ? 0.2 : 0.1)
            ))
            .foregroundStyle(isSelected ? Color(nsColor: accent) : Color.primary)
    }
}
