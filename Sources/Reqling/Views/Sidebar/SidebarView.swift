import AppKit
import ReqlingKit
import SwiftUI

/// Projects with their folders and requests, under a filter field. Selection, expansion, and every edit route
/// through `AppModel`; filtering through `SidebarViewModel`, and dragging through `SidebarDragController`.
struct SidebarView: View {
    @Bindable var model: AppModel
    @State private var drag: SidebarDragController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// `drag` is for tests, which drive the drag and clicks through it: synthesized mouse events never reach a `List`
    /// row that isn't `.draggable`.
    init(model: AppModel, drag: SidebarDragController? = nil) {
        self.model = model
        _drag = State(initialValue: drag ?? SidebarDragController(model: model, system: .live))
    }

    var body: some View {
        let sidebar = model.sidebar
        let sections = sidebar.sections
        ScrollViewReader { proxy in
            dragHost(
                List(selection: selection) {
                    Section {
                        ForEach(sections) { section in
                            SidebarProjectGroup(section: section, isFiltering: sidebar.isFiltering, model: model)
                        }
                    } header: {
                        Text("Projects")
                    }
                }
                .listStyle(.sidebar)
                .onDeleteCommand(perform: moveSelectionToTrash)
            )
            .onChange(of: model.renaming) { _, item in
                if let item {
                    reveal(item, with: proxy)
                }
            }
            .onChange(of: model.selection) { _, item in
                if let item, drag.listHost.isOnScreen {
                    scroll(to: item, with: proxy)
                }
            }
        }
        .overlay {
            if model.library.projects.isEmpty {
                SidebarEmptyState(model: model)
            } else if sections.isEmpty {
                SidebarNoMatches(sidebar: sidebar)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            SidebarSearchBar(sidebar: sidebar)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                SidebarBatchRunBar(model: model)
                SidebarFooter(model: model)
            }
        }
        .toolbar {
            ToolbarItem(id: MainToolbarItemID.addProject, placement: .automatic) {
                SidebarAddProjectMenu(model: model)
            }
        }
    }

    /// The list's selection, which a drag hides while it holds the selected row: the table draws the highlight, so it
    /// can't fade with the row. Only the table's keys set it, never while a drag is under way; rows select themselves
    /// on a click (`SidebarDragController.click(_:)`).
    private var selection: Binding<SidebarItem?> {
        Binding(
            get: { [drag, model] in
                model.selection.flatMap { drag.isDragged($0) ? nil : $0 }
            },
            set: { [drag, model] item in
                if drag.isIdle {
                    model.selection = item
                }
            }
        )
    }

    /// The drag's wiring around the list, lifted out of `body` for the type-checker.
    private func dragHost<Content: View>(_ list: Content) -> some View {
        list
            .background { SidebarListHostReader(host: drag.listHost) }
            .overlay { SidebarListGeometryReader(role: .visible) }
            // The list runs under the filter bar and footer, and its rows' frames with it, so the overlay must too: inset
            // by the safe area, the monitor's points would sit the filter bar's height above the rows' frames.
            .overlay { SidebarDragOverlay(drag: drag).ignoresSafeArea() }
            .environment(drag)
            .onPreferenceChange(SidebarDragGeometryKey.self) { [drag] geometry in
                // Preference changes arrive on the main thread.
                MainActor.assumeIsolated {
                    drag.geometryChanged(geometry)
                }
            }
            .onChange(of: model.renaming) { _, item in
                if item != nil {
                    drag.teardown()
                }
            }
            .onChange(of: model.sidebar.isFiltering) { _, isFiltering in
                if isFiltering {
                    drag.teardown()
                }
            }
            .onChange(of: reduceMotion, initial: true) { _, reduceMotion in
                drag.reducesMotion = reduceMotion
            }
            .onDisappear { drag.teardown() }
    }

    /// Brings a row being renamed into view, or ends the rename when the sidebar is collapsed. A new request or folder
    /// can land below the fold or behind a collapsed column, where no row and so no field exists yet; left alone, the
    /// field would appear whenever the row did and take the keyboard from whatever had it by then. A visible row stays.
    private func reveal(_ item: SidebarItem, with proxy: ScrollViewProxy) {
        guard drag.listHost.isOnScreen else {
            model.endRename(item, to: nil)
            return
        }
        scroll(to: item, with: proxy)
    }

    /// Scrolls only as far as it takes to show the whole row, so a click on a row wholly in view never moves the list. Every
    /// selection comes here as well as renames: the table scrolls to the rows its own keys select, but not to the folder
    /// ← selects (`AppModel.collapseFolderOrSelectParent(at:)`) or to an item an MCP client reveals.
    private func scroll(to item: SidebarItem, with proxy: ScrollViewProxy) {
        switch item {
        case .project(let project):
            proxy.scrollTo(project)
        case .node(_, let node):
            proxy.scrollTo(node)
        }
    }

    /// The Delete key and Edit ▸ Delete take the same path as the row's context menu, asking before anything moves to
    /// the Trash, so the keyboard reaches what was otherwise mouse-only.
    private func moveSelectionToTrash() {
        if let selection = model.selection {
            model.requestTrash(selection)
        }
    }
}

/// The toolbar's add menu, beside the sidebar toggle. It stays while the library is empty: the empty state offers the
/// same actions, but the toolbar is the one place they are always found.
private struct SidebarAddProjectMenu: View {
    let model: AppModel

    var body: some View {
        Menu {
            Button("New Project…") { model.sheet = .newProject }
            Button("Add Project Folder…") { model.openProjectFolder() }
            Button("Import…") { model.sheet = .importProject }
        } label: {
            Label("Add a Project", systemImage: "plus")
        }
        .menuIndicator(.hidden)
        .help("Create a project, add an existing project folder, or import a Postman collection or OpenAPI document")
        .accessibilityLabel("Add a project")
    }
}

private struct SidebarEmptyState: View {
    let model: AppModel

    var body: some View {
        CompactEmptyState(
            systemImage: "shippingbox",
            title: "No Projects",
            message: "A project holds your requests and their environments."
        ) {
            Button("New Project…") { model.sheet = .newProject }
                .buttonStyle(.borderedProminent)
            Button("Add Project Folder…") { model.openProjectFolder() }
            Button("Import…") { model.sheet = .importProject }
        }
    }
}

private struct SidebarNoMatches: View {
    let sidebar: SidebarViewModel

    var body: some View {
        CompactEmptyState(
            systemImage: "line.3.horizontal.decrease.circle",
            title: "No Matches",
            message: "No project, folder, or request matches the filter."
        ) {
            Button("Clear Filter") { sidebar.clearFilters() }
        }
    }
}

private struct SidebarFooter: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Button {
                model.newRequest()
            } label: {
                Label("New Request", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            .disabled(model.activeProjectID == nil)
            .help("Add a request beside the selection")
            Spacer()
            Menu {
                Button("New Folder") { model.newFolder() }
                    .disabled(model.activeProjectID == nil)
                Divider()
                Button("New Project…") { model.sheet = .newProject }
                Button("Add Project Folder…") { model.openProjectFolder() }
                Button("Import…") { model.sheet = .importProject }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .accessibilityLabel("More ways to add")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("More ways to add")
            .accessibilityLabel("More ways to add")
            .iconButtonChrome()
        }
        .padding(.horizontal, 12)
        // The menu's icon tile carries its own padding, so the bar's vertical inset is that much smaller.
        .padding(.top, 9)
        .padding(.bottom, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}
