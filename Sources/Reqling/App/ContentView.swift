import ReqlingKit
import SwiftUI

/// The main window: projects on the side, and the selected request, folder, project, or Settings in the detail.
struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        presentations(
            NavigationSplitView {
                SidebarView(model: model)
                    .navigationSplitViewColumnWidth(min: 220, ideal: 300, max: 380)
            } detail: {
                DetailView(model: model)
                    .frame(minWidth: 520, minHeight: 420)
            }
            .toolbar { MainToolbar(model: model) }
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            // `DetailTitleBar` draws the visible title; the scene's own title stays for the Window menu and VoiceOver.
            .toolbar(removing: .title)
            .background {
                WindowToolbarConfigurator()
                    .frame(width: 0, height: 0)
                #if DEBUG
                if ScreenshotMode.current != nil {
                    ScreenshotWindowConfigurator()
                        .frame(width: 0, height: 0)
                }
                #endif
            }
        )
        .preferredColorScheme(Self.colorScheme(for: model.settings.settings.theme))
        .onChange(of: model.library.projects) { _, _ in
            model.libraryDidChange()
        }
    }

    /// Sheets and alerts, lifted out of `body` to keep its type-check scope small.
    private func presentations<Content: View>(_ content: Content) -> some View {
        content
            .sheet(item: $model.sheet) { sheet in
                AppSheetView(sheet: sheet, model: model)
                    .modifier(AlertPresenter(model: model, isInSheet: true))
            }
            .modifier(AlertPresenter(model: model, isInSheet: false))
            .alert("Rename", isPresented: $model.isRenaming) {
                TextField("Name", text: Binding(get: { model.renaming?.name ?? "" }, set: { model.renaming?.name = $0 }))
                Button("Rename") { model.commitRename() }
                Button("Cancel", role: .cancel) { model.cancelRename() }
            }
            .alert(
                "Restart to Update?",
                isPresented: Binding(get: { model.updates.restartPrompt != nil }, set: { if !$0 { model.dismissUpdateRestartPrompt() } }),
                presenting: model.updates.restartPrompt
            ) { _ in
                Button("Install & Relaunch") { model.installUpdate() }
                Button("Later", role: .cancel) { model.dismissUpdateRestartPrompt() }
            } message: { staged in
                Text("Reqling \(staged.release.version.description) is downloaded and verified. Reqling quits, installs it, and opens again. "
                    + "You can also install it later from Settings ▸ App Updates.")
            }
            .confirmationDialog(
                "Change “\(model.kindChangePending?.name ?? "")” to \((model.kindChangePending?.kind ?? .http).title)?",
                isPresented: Binding(get: { model.kindChangePending != nil }, set: { if !$0 { model.kindChangePending = nil } }),
                titleVisibility: .visible,
                presenting: model.kindChangePending
            ) { change in
                Button("Change to \(change.kind.title)", role: .destructive) { model.applyKindChange(change) }
            } message: { change in
                Text(change.kind == .grpc
                    ? "Its auth, headers, host, and timeout carry over. Its method, query, body, and run history are discarded."
                    : "Its auth, metadata, target, and deadline carry over. Its service, method, messages, and run history are discarded.")
            }
            .confirmationDialog(
                "Move this project to the Trash?",
                isPresented: Binding(get: { model.projectPendingDeletion != nil }, set: { if !$0 { model.projectPendingDeletion = nil } }),
                titleVisibility: .visible,
                // The action takes the ID from here, not the model: dismissal may clear `projectPendingDeletion` first.
                presenting: model.projectPendingDeletion
            ) { project in
                Button("Move to Trash", role: .destructive) { model.deleteProject(project) }
            } message: { _ in
                Text("Its folder goes to the Trash, where Finder can put it back. Its secret values are removed from your Keychain.")
            }
            .modifier(HistoryClearConfirmation(model: model))
    }

    static func colorScheme(for theme: AppTheme) -> ColorScheme? {
        switch theme {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// Asks before run history is cleared; it lives only on this Mac, so nothing can bring it back.
private struct HistoryClearConfirmation: ViewModifier {
    let model: AppModel

    func body(content: Content) -> some View {
        content.confirmationDialog(
            model.historyClearPending?.title ?? "",
            isPresented: Binding(get: { model.historyClearPending != nil }, set: { if !$0 { model.historyClearPending = nil } }),
            titleVisibility: .visible,
            // The action takes the scope from here: dismissal may clear `historyClearPending` first.
            presenting: model.historyClearPending
        ) { scope in
            Button("Clear History", role: .destructive) { model.clearHistory(scope) }
        } message: { _ in
            Text("Past runs and their responses are deleted from this Mac. This can't be undone.")
        }
    }
}

/// Presents `model.alert` from the window's frontmost presentation. A window shows one presentation at a time, so an
/// alert attached beneath an open sheet stays hidden: the root presents only while no sheet is up, and the sheet's
/// content presents while one is.
private struct AlertPresenter: ViewModifier {
    let model: AppModel
    let isInSheet: Bool

    func body(content: Content) -> some View {
        content.alert(item: Binding(get: { (model.sheet != nil) == isInSheet ? model.alert : nil }, set: { model.alert = $0 })) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message))
        }
    }
}

private struct AppSheetView: View {
    let sheet: AppSheet
    let model: AppModel

    var body: some View {
        switch sheet {
        case .newProject:
            NewProjectSheet(model: model)
        case .environments(let project):
            EnvironmentEditorSheet(editor: EnvironmentEditorModel(projectID: project, app: model))
        case .projectSettings(let project):
            ProjectSettingsSheet(
                settings: ProjectSettingsModel(projectID: project, app: model),
                tokenContext: model.tokenContext(for: project)
            )
        }
    }
}

private struct DetailView: View {
    let model: AppModel

    var body: some View {
        // One view whose identity never changes: SwiftUI rebuilds the inspector's split column whenever the identity of
        // the view `.inspector` modifies changes, which `content`'s does with every request (its `.id`, or its branch),
        // and a rebuilt column comes back at its minimum width, dropping the width the person dragged it to.
        ZStack { content }
            .inspector(isPresented: Binding(
                get: { model.isInspectorShown && model.editor != nil },
                // Only the person hides it; the inspector going with its editor must not forget that it was open.
                set: { isPresented in
                    if model.editor != nil {
                        model.isInspectorShown = isPresented
                    }
                }
            )) {
                if let editor = model.editor {
                    InspectorContent(model: model, editor: editor)
                        .id(editor.identity)
                        // One range for both panels, so switching between them keeps the width the person chose.
                        .inspectorColumnWidth(min: 220, ideal: 260, max: 480)
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if model.isShowingSettings {
            SettingsScreen(model: model)
        } else if let editor = model.editor {
            switch editor {
            case .http(let http):
                RequestEditorView(editor: http, model: model)
                    .id(editor.identity)
            case .grpc(let grpc):
                GRPCEditorView(editor: grpc, model: model)
                    .id(editor.identity)
            }
        } else if case .node(let project, let node)? = model.selection, let folder = model.library.document(project)?.folder(node) {
            FolderDetailView(folder: folder, projectID: project, model: model)
        } else if let project = shownProject {
            ProjectDetailView(project: project, model: model)
        } else {
            ContentUnavailableView {
                Label("Nothing Selected", systemImage: "curlybraces")
            } description: {
                Text("Choose a request in the sidebar, or create one.")
            } actions: {
                if model.library.projects.isEmpty {
                    Button("New Project…") { model.sheet = .newProject }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("New Request") { model.newRequest() }
                }
            }
        }
    }

    /// The selected project, or a selected item's project when that project did not load, so its "Project Unavailable"
    /// state shows instead of an empty detail.
    private var shownProject: LibraryProject? {
        guard let selection = model.selection, let project = model.library.project(selection.projectID) else {
            return nil
        }
        return selection.nodeID == nil || project.document == nil ? project : nil
    }
}

/// The inspector's panel: the run history, or beside a GraphQL request, its schema, with a picker between the two.
struct InspectorContent: View {
    let model: AppModel
    let editor: RequestEditor

    var body: some View {
        let graphQL = editor.asHTTP.flatMap { http in http.graphQL.map { (http, $0) } }
        VStack(spacing: 0) {
            if graphQL != nil {
                SectionPicker(
                    "Inspector",
                    selection: Binding(get: { model.shownInspectorPanel }, set: { model.inspectorPanel = $0 }),
                    options: InspectorPanel.allCases,
                    label: Self.title(for:)
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.top, 10)
            }
            if let (http, schema) = graphQL, model.shownInspectorPanel == .graphQLSchema {
                GraphQLSchemaBrowser(editor: http, model: schema)
            } else {
                RunHistoryInspector(history: editor.history)
            }
        }
    }

    static func title(for panel: InspectorPanel) -> String {
        switch panel {
        case .history: "History"
        case .graphQLSchema: "Schema"
        }
    }
}

private struct MainToolbar: ToolbarContent {
    let model: AppModel

    var body: some ToolbarContent {
        ToolbarItem(id: MainToolbarItemID.title, placement: .navigation) {
            DetailTitleBar(model: model)
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarItem(id: MainToolbarItemID.trailing, placement: .primaryAction) {
            if let project = model.activeProjectID, let document = model.library.document(project) {
                EnvironmentPicker(document: document, active: model.activeEnvironmentID(for: project), model: model)
            }
        }
        ToolbarItem(id: MainToolbarItemID.inspector, placement: .primaryAction) {
            if model.editor != nil {
                InspectorToolbarButton(isShown: model.isInspectorShown) { model.toggleInspector() }
            }
        }
        ToolbarItem(id: MainToolbarItemID.settings, placement: .primaryAction) {
            SettingsToolbarButton(badge: model.updates.badgeState) { model.openSettingsFromToolbar() }
        }
    }
}

/// The active environment of the project the toolbar acts on, with that project's name beneath it, since every project
/// has its own Default and, with nothing selected, the toolbar falls back to the first project.
///
/// A toolbar `Menu` with the system button style becomes a native item that keeps only its label's first line of text;
/// one with its own button style (`EnvironmentPickerButtonStyle`) is drawn by SwiftUI, both lines included.
private struct EnvironmentPicker: View {
    let document: ProjectDocument
    let active: EnvironmentID?
    let model: AppModel

    var body: some View {
        Menu {
            // Inline, so the active environment gets the menu's own checkmark; a `Label`'s image isn't drawn in a menu.
            Picker(document.name, selection: activeSelection) {
                ForEach(document.allEnvironments) { environment in
                    Text(environment.name).tag(environment.id)
                }
            }
            .pickerStyle(.inline)
            Divider()
            Button("Edit Environments…") { model.sheet = .environments(document.id) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "square.stack.3d.up")
                HuggingCenteredStack(maxWidth: Self.maxNameWidth) {
                    Text(activeName)
                    Text(document.name)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                // The middle, so a long name keeps both its start and its end readable.
                .lineLimit(1)
                .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            // One element, or the icon, each line, and the chevron each read as an Environment button of their own.
            .accessibilityElement(children: .combine)
        }
        .menuStyle(.button)
        .buttonStyle(EnvironmentPickerButtonStyle())
        .menuIndicator(.hidden)
        .help("The environment \(document.name)'s requests resolve variables against")
        .accessibilityLabel("Environment")
        .accessibilityValue("\(activeName), in \(document.name)")
    }

    /// Past this, a name's middle is elided rather than the label crowding the title. The menu's section header and the
    /// tooltip show the project's whole name.
    private static let maxNameWidth: CGFloat = 120

    /// The active environment, or Default when none is chosen or the chosen one is gone.
    private var activeID: EnvironmentID {
        active.flatMap { document.environment($0)?.id } ?? document.defaultEnvironment.id
    }

    private var activeName: String {
        document.environment(activeID)?.name ?? RequestEnvironment.defaultName
    }

    private var activeSelection: Binding<EnvironmentID> {
        Binding {
            activeID
        } set: { id in
            model.setActiveEnvironment(id, for: document.id)
        }
    }
}

/// The environment picker's label chrome: the hover and press tint the toolbar's own buttons show, and their dimming in
/// an inactive window, neither of which a `.plain` label gets.
private struct EnvironmentPickerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        EnvironmentPickerLabel(isPressed: configuration.isPressed) {
            configuration.label
        }
    }
}

/// Tracks the pointer for `EnvironmentPickerButtonStyle`, since `@State` can't live in a `ButtonStyle`.
private struct EnvironmentPickerLabel<Content: View>: View {
    let isPressed: Bool
    @ViewBuilder let content: Content

    @State private var isHovered = false
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        content
            .padding(.horizontal, 10)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.primary.opacity(isPressed ? 0.16 : isHovered ? 0.08 : 0)))
            .contentShape(Capsule())
            .opacity(activeState == .inactive ? 0.5 : 1)
            .onHover { isHovered = $0 }
    }
}

/// Shows or hides the inspector beside the selected request, on whichever panel it last showed.
private struct InspectorToolbarButton: View {
    let isShown: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "sidebar.trailing")
        }
        .help(isShown ? "Hide Inspector (⌥⌘I)" : "Show Inspector (⌥⌘I)")
        .accessibilityLabel("Inspector")
        .accessibilityValue(isShown ? "Shown" : "Hidden")
    }
}

/// The gear, with a dot when an update is available (accent) or ready to install (green); either opens App Updates.
struct SettingsToolbarButton: View {
    let badge: AppUpdateBadgeState
    let action: () -> Void
    @Environment(\.appAccent) private var accent

    var body: some View {
        Button(action: action) {
            Image(systemName: "gearshape")
                .overlay(alignment: .topTrailing) {
                    if let color = badgeColor {
                        Circle()
                            .fill(color)
                            .frame(width: 7, height: 7)
                            // A fixed dark ring cuts the dot out of the glyph in both appearances; `.background`
                            // resolves white in light mode and reads as a halo instead.
                            .overlay(Circle().strokeBorder(Color(white: 0.12), lineWidth: 1))
                            .offset(x: 3, y: -2)
                    }
                }
        }
        .help(helpText)
        .accessibilityLabel("Settings")
        .accessibilityValue(badge.accessibilityValue)
    }

    private var badgeColor: Color? {
        switch badge {
        case .none: nil
        case .updateAvailable: Color(nsColor: accent)
        case .readyToInstall: .green
        }
    }

    private var helpText: String {
        switch badge {
        case .none: "Settings"
        case .updateAvailable: "An update is available"
        case .readyToInstall: "An update is ready to install"
        }
    }
}
