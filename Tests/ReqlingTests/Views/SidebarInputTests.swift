import AppKit
import ReqlingKit
import SwiftUI
import XCTest

@testable import Reqling

/// Keys and clicks as AppKit delivers them, against the real `List` beside another field: the key monitor only sees
/// events sent through `NSApp`, and only a neighbour proves Return elsewhere keeps working.
@MainActor
final class SidebarInputTests: XCTestCase {
    private var fixture: AppFixture!
    private var project: SnapshotProject!
    private var window: SidebarInputTestWindow!
    private var controller: NSHostingController<AnyView>!
    private var drag: SidebarDragController!

    override func setUp() async throws {
        fixture = AppFixture()
        project = try SnapshotProject.make(in: fixture)
        // The real button is up while a test runs, which the drag's watch would take for a lost mouse-up.
        drag = SidebarDragController(model: fixture.model, system: SidebarDragSystem(
            sleep: { _ in },
            isEscapePressed: { false },
            isPointerDown: { true }
        ))
        controller = NSHostingController(rootView: AnyView(
            HStack(spacing: 0) {
                SidebarView(model: fixture.model, drag: drag)
                    .frame(width: 280, height: 420)
                TextField("Neighbour", text: .constant(""))
                    .frame(width: 200)
            }
            .transaction { $0.animation = nil }
        ))
        let frame = NSRect(x: -3_000, y: -3_000, width: 480, height: 420)
        window = SidebarInputTestWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setFrame(frame, display: false)
        window.orderFront(nil)
    }

    override func tearDown() async throws {
        closeSnapshotWindow(window, controller: controller)
        window = nil
        controller = nil
        drag = nil
        fixture.tearDown()
        fixture = nil
    }

    func testReturnRenamesTheSelectedProjectFolderOrRequestAndHandsTheKeyboardBack() async throws {
        let items: [(item: SidebarItem, name: String)] = [
            (.node(project.id, project.listUsers), "List users"),
            (.node(project.id, project.folder), "Admin"),
            (.project(project.id), "Sample API")
        ]
        for (item, name) in items {
            let table = try await focusSidebar(selecting: item)
            try sendKey()
            let editor = try await waitForRenameEditor()
            XCTAssertEqual(editor.string, name)

            editor.selectAll(nil)
            editor.insertText("\(name) 2", replacementRange: editor.selectedRange())
            try sendKey(toWindow: true)

            await waitUntil("the field to close with \(name)") { self.renameField() == nil && self.window.firstResponder === table }
            XCTAssertEqual(self.name(of: item), "\(name) 2")
            XCTAssertNil(fixture.model.renaming)
        }
    }

    func testEscapeKeepsTheNameAndArrowKeysMoveOnThroughTheSidebar() async throws {
        let table = try await focusSidebar(selecting: .node(project.id, project.createUser))
        try sendKey()
        let editor = try await waitForRenameEditor()
        editor.insertText("Discarded", replacementRange: editor.selectedRange())

        try sendKey(53, characters: "\u{1b}", toWindow: true)
        await waitUntil("the field to close") { self.renameField() == nil && self.window.firstResponder === table }
        XCTAssertEqual(name(of: .node(project.id, project.createUser)), "Create user")

        try sendKey(126, characters: "\u{f700}", toWindow: true)
        await waitUntil("the selection to move up") { self.fixture.model.selection == .node(self.project.id, self.project.listUsers) }
    }

    func testKeypadEnterStartsARename() async throws {
        _ = try await focusSidebar(selecting: .node(project.id, project.listUsers))
        try sendKey(76, characters: "\u{3}", flags: [.numericPad])
        let editor = try await waitForRenameEditor()
        XCTAssertEqual(editor.string, "List users")
    }

    /// ⌘Return sends the request, and the other modifiers make other shortcuts.
    func testModifiedReturnDoesNotRename() async throws {
        let table = try await focusSidebar(selecting: .node(project.id, project.listUsers))
        for flags: NSEvent.ModifierFlags in [.command, .control, .option, .shift] {
            try sendKey(flags: flags)
            settle()
            XCTAssertNil(fixture.model.renaming, "\(flags)")
            XCTAssertTrue(window.firstResponder === table)
        }
    }

    func testReturnInAnotherFieldDoesNotRename() async throws {
        _ = try await focusSidebar(selecting: .node(project.id, project.listUsers))
        let neighbour = try XCTUnwrap(descendants(of: NSTextField.self).first { $0.placeholderString == "Neighbour" })
        XCTAssertTrue(window.makeFirstResponder(neighbour))

        try sendKey()
        settle()

        XCTAssertNil(fixture.model.renaming)
        XCTAssertNil(renameField())
    }

    func testAReadOnlyProjectsRowIgnoresReturn() async throws {
        let projectFile = try XCTUnwrap(fixture.library.project(project.id)?.url.appendingPathComponent("project.json"))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: projectFile)) as? [String: Any])
        json["formatVersion"] = ProjectDocument.currentFormatVersion + 1
        try JSONSerialization.data(withJSONObject: json).write(to: projectFile)
        fixture.library.reload(project.id)
        fixture.model.libraryDidChange()
        let table = try await focusSidebar(selecting: .node(project.id, project.listUsers))

        try sendKey()
        settle()

        XCTAssertNil(fixture.model.renaming)
        XCTAssertTrue(window.firstResponder === table)
    }

    func testANewRequestOrFolderStartsRenamedWithTheKeyboard() async throws {
        let table = try await focusSidebar(selecting: .node(project.id, project.listUsers))
        for (create, name) in [({ self.fixture.model.newRequest() }, "New Request"), ({ self.fixture.model.newFolder() }, "New Folder")] {
            create()
            let editor = try await waitForRenameEditor()
            XCTAssertEqual(editor.string, name)
            let item = try XCTUnwrap(fixture.model.selection)

            editor.insertText("Named", replacementRange: editor.selectedRange())
            try sendKey(toWindow: true)

            await waitUntil("the \(name) field to close") { self.renameField() == nil && self.window.firstResponder === table }
            XCTAssertEqual(self.name(of: item), "Named")
        }
    }

    /// Renaming the same row again before SwiftUI redraws (Rename from the menu of the row being edited, whose
    /// right-click ended the edit) still gets a field that takes the keyboard and reports its own end.
    func testRenamingARowAgainBeforeARedrawGetsAFreshField() async throws {
        let item = SidebarItem.node(project.id, project.listUsers)
        let table = try await focusSidebar(selecting: item)
        try sendKey()
        _ = try await waitForRenameEditor()

        try sendKey(53, characters: "\u{1b}", toWindow: true)
        fixture.model.beginRename(item)

        let editor = try await waitForRenameEditor()
        editor.insertText("Users", replacementRange: editor.selectedRange())
        try sendKey(toWindow: true)
        await waitUntil("the field to close") { self.renameField() == nil && self.window.firstResponder === table }
        XCTAssertEqual(name(of: item), "Users")
    }

    /// ⌘N while a row is renamed starts the new one renamed and keeps what was typed for the first, as clicking away does.
    func testANewRequestMidRenameKeepsTheNameTyped() async throws {
        _ = try await focusSidebar(selecting: .node(project.id, project.listUsers))
        try sendKey()
        let editor = try await waitForRenameEditor()
        editor.insertText("Users", replacementRange: editor.selectedRange())

        fixture.model.newRequest()

        let newEditor = try await waitForRenameEditor()
        XCTAssertEqual(newEditor.string, "New Request")
        XCTAssertEqual(name(of: .node(project.id, project.listUsers)), "Users")
    }

    /// A project longer than the sidebar puts the new row out of view, at its end or in the folder last in it, so it
    /// scrolls in to be named.
    func testANewRequestBelowTheFoldScrollsIntoViewRenamed() async throws {
        try fixture.library.mutate(project.id) { document in
            for index in 0..<40 {
                try document.insert(.request(RequestItem(name: "Extra \(index)", kind: .http(HTTPRequestSpec()))), into: nil, at: 0)
            }
        }
        for parent: SidebarItem in [.project(project.id), .node(project.id, project.folder)] {
            let table = try await focusSidebar(selecting: parent)
            table.scrollRowToVisible(0)

            fixture.model.newRequest()

            let editor = try await waitForRenameEditor()
            XCTAssertEqual(editor.string, "New Request", "\(parent)")
            try sendKey(53, characters: "\u{1b}", toWindow: true)
            await waitUntil("the field to close") { self.renameField() == nil }
        }
    }

    /// A collapsed sidebar keeps its list, hidden, but builds no rows, so the new row has no field to name it in.
    func testANewRequestWithTheSidebarCollapsedIsNotRenamed() async throws {
        controller.rootView = AnyView(
            NavigationSplitView(columnVisibility: .constant(.detailOnly)) {
                SidebarView(model: fixture.model)
            } detail: {
                TextField("Detail", text: .constant(""))
            }
        )
        fixture.model.selection = .node(project.id, project.listUsers)
        await waitUntil("the hidden sidebar's list") {
            self.settle()
            return self.descendants(of: NSTableView.self).first?.isHiddenOrHasHiddenAncestor == true
        }

        fixture.model.newRequest()
        await waitUntil("the rename to end") {
            self.settle()
            return self.fixture.model.renaming == nil
        }

        XCTAssertNotEqual(fixture.model.selection, .node(project.id, project.listUsers))
        XCTAssertNil(renameField())
    }

    func testANewRequestTheFilterHidesIsNotRenamed() async throws {
        fixture.model.sidebar.query = "users"
        _ = try await focusSidebar(selecting: .node(project.id, project.listUsers))

        fixture.model.newRequest()
        settle()

        XCTAssertNotNil(fixture.model.selection?.nodeID)
        XCTAssertNil(fixture.model.renaming)
    }

    /// Folders are rows of their own, so → and ← open and close them, and ← from inside one selects it rather than
    /// passing it for the project. A top-level row's ← is left to the table.
    func testArrowKeysOpenAndCloseFoldersAndLeaveThem() async throws {
        let folder = SidebarItem.node(project.id, project.folder)
        let purgeCache = try XCTUnwrap(fixture.library.document(project.id)?.children(of: project.folder)?.first?.id)
        _ = try await focusSidebar(selecting: folder)

        try sendKey(123, characters: "\u{f702}", flags: [.numericPad, .function])
        await waitUntil("the folder to close") { !self.fixture.model.isExpanded(folder: self.project.folder, in: self.project.id) }
        XCTAssertFalse(fixture.model.collapseFolderOrSelectParent(at: folder), "A closed top-level folder's ← is the table's")
        try sendKey(124, characters: "\u{f703}", flags: [.numericPad, .function])
        await waitUntil("the folder to open") { self.fixture.model.isExpanded(folder: self.project.folder, in: self.project.id) }

        _ = try await focusSidebar(selecting: .node(project.id, purgeCache))
        try sendKey(123, characters: "\u{f702}", flags: [.numericPad, .function])
        await waitUntil("the selection to move to the folder") { self.fixture.model.selection == folder }
        XCTAssertTrue(fixture.model.isExpanded(folder: project.folder, in: project.id))
    }

    /// ← from deep in a long folder selects the folder above the fold and brings it into view, as the table does for
    /// the rows its own keys select.
    func testLeftArrowScrollsTheFolderItSelectsIntoView() async throws {
        let folder = project.folder
        try fixture.library.mutate(project.id) { document in
            for index in 0..<40 {
                try document.insert(.request(RequestItem(name: "Extra \(index)", kind: .http(HTTPRequestSpec()))), into: folder)
            }
        }
        let last = try XCTUnwrap(fixture.library.document(project.id)?.children(of: folder)?.last?.id)
        let table = try await focusSidebar(selecting: .node(project.id, last))
        let top = table.visibleRect.minY

        try sendKey(123, characters: "\u{f702}", flags: [.numericPad, .function])

        await waitUntil("the folder to scroll into view") {
            self.settle()
            guard self.fixture.model.selection == .node(self.project.id, folder), table.selectedRow >= 0 else {
                return false
            }
            let row = table.rect(ofRow: table.selectedRow)
            return row.minY < top && table.visibleRect.contains(row)
        }
    }

    /// A row takes its own click (`sidebarRowClick`), which synthesized mouse events can't reach, so this drives the
    /// controller the click calls: it selects the row and gives the table the keyboard the table's own click did.
    func testAClickSelectsTheRowAndGivesTheTableTheKeyboard() async throws {
        let table = try await focusSidebar(selecting: .node(project.id, project.listUsers))
        let neighbour = try XCTUnwrap(descendants(of: NSTextField.self).first { $0.placeholderString == "Neighbour" })
        XCTAssertTrue(window.makeFirstResponder(neighbour))

        drag.click(.node(project.id, project.createUser))

        await waitUntil("the table to take the keyboard") {
            self.settle()
            return self.window.firstResponder === table
        }
        XCTAssertEqual(fixture.model.selection, .node(project.id, project.createUser))
        try sendKey(125, characters: "\u{f701}", toWindow: true)
        await waitUntil("the selection to move down") { self.fixture.model.selection == .node(self.project.id, self.project.folder) }
    }

    /// A click on a folder's row opens or closes it too, but not while filtering or renaming, on Control-click, or on a
    /// double-click's second click.
    func testAClickTogglesAFolderOnlyWhenNothingElseClaimsIt() {
        XCTAssertTrue(SidebarNodeRow.clickToggles(isFiltering: false, isRenaming: false, modifiers: [], clickCount: 1))
        XCTAssertFalse(SidebarNodeRow.clickToggles(isFiltering: true, isRenaming: false, modifiers: [], clickCount: 1))
        XCTAssertFalse(SidebarNodeRow.clickToggles(isFiltering: false, isRenaming: true, modifiers: [], clickCount: 1))
        XCTAssertFalse(SidebarNodeRow.clickToggles(isFiltering: false, isRenaming: false, modifiers: .control, clickCount: 1))
        XCTAssertFalse(SidebarNodeRow.clickToggles(isFiltering: false, isRenaming: false, modifiers: [], clickCount: 2))
    }

    /// The table can't fade the highlight it draws, so a drag hides the selection while it holds the selected row; the
    /// table's answering deselection must not reach the model, and the highlight comes back after.
    func testDraggingTheSelectedRowKeepsItSelected() async throws {
        let selected = SidebarItem.node(project.id, project.listUsers)
        let table = try await focusSidebar(selecting: selected)
        let row = table.selectedRow

        drag.sourceChanged(selected)
        await waitUntil("the highlight to hide") {
            self.settle()
            return table.selectedRow == -1
        }
        drag.sourceEnded(selected)
        await waitUntil("the highlight to return") {
            self.settle()
            return table.selectedRow == row
        }

        XCTAssertEqual(fixture.model.selection, selected)
    }

    /// A drag holds the keys that would act on the sidebar beneath it, and Escape cancels it until the mouse comes up.
    func testADragHoldsTheSidebarsKeysAndEscapeCancelsIt() async throws {
        let dragged = SidebarItem.node(project.id, project.createUser)
        _ = try await focusSidebar(selecting: .node(project.id, project.listUsers))
        drag.sourceChanged(dragged)
        settle()

        try sendKey()
        settle()
        XCTAssertNil(fixture.model.renaming, "Return renames nothing mid-drag")

        try sendKey(53, characters: "\u{1b}")
        XCTAssertFalse(drag.isIdle)
        XCTAssertNil(drag.state.session, "Cancelled, waiting for the mouse to come up")

        drag.sourceEnded(dragged)
        XCTAssertTrue(drag.isIdle)
        XCTAssertEqual(fixture.library.document(project.id)?.items.map(\.id), [project.listUsers, project.createUser, project.folder])
    }

    func testCommittedNamesAreTrimmedAndBlankOrUnchangedOnesKeepTheOldName() {
        XCTAssertEqual(InlineRenameField.committedName("  Users ", replacing: "List users"), "Users")
        XCTAssertNil(InlineRenameField.committedName("   ", replacing: "List users"))
        XCTAssertNil(InlineRenameField.committedName(" List users ", replacing: "List users"))
    }

    // MARK: - Helpers

    /// Selects `item` and gives the sidebar's table the keyboard, as a click on the row would.
    private func focusSidebar(selecting item: SidebarItem) async throws -> NSTableView {
        fixture.model.selection = item
        settle()
        let table = try XCTUnwrap(descendants(of: NSTableView.self).first)
        XCTAssertTrue(window.makeFirstResponder(table))
        await waitUntil("the selected row's key monitor") {
            self.settle()
            return self.descendants(of: SidebarRowKeyMonitorView.self).contains { $0.window === self.window }
        }
        return table
    }

    /// Waits for the field to take the keyboard, which it does a turn after it appears.
    private func waitForRenameEditor(file: StaticString = #filePath, line: UInt = #line) async throws -> NSTextView {
        await waitUntil("the rename field to take the keyboard", file: file, line: line) {
            self.settle()
            guard let editor = self.renameField()?.currentEditor() else {
                return false
            }
            return self.window.firstResponder === editor
        }
        return try XCTUnwrap(renameField()?.currentEditor() as? NSTextView, file: file, line: line)
    }

    /// Through `NSApp` by default, so local monitors see it as they do a real key. Keys meant for the field or the
    /// table go to the window, which XCTest's host does not make the application's key window.
    private func sendKey(
        _ keyCode: UInt16 = 36,
        characters: String = "\r",
        flags: NSEvent.ModifierFlags = [],
        toWindow: Bool = false
    ) throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ))
        if toWindow {
            window.sendEvent(event)
        } else {
            NSApplication.shared.sendEvent(event)
        }
    }

    /// Runs one pass of the run loop without waiting, so SwiftUI applies pending updates and lays the window out.
    private func settle() {
        RunLoop.current.run(mode: .default, before: .distantPast)
        window.layoutIfNeeded()
        window.displayIfNeeded()
    }

    private func renameField() -> SelfFocusingTextField? {
        descendants(of: SelfFocusingTextField.self).first
    }

    private func name(of item: SidebarItem) -> String? {
        let document = fixture.library.document(item.projectID)
        return item.nodeID.map { document?.node($0)?.name } ?? document?.name
    }

    private func descendants<View: NSView>(of type: View.Type, in root: NSView? = nil) -> [View] {
        let root = root ?? controller.view
        return (root as? View).map { [$0] } ?? root.subviews.flatMap { descendants(of: type, in: $0) }
    }
}

/// XCTest never makes an offscreen host the application's key window, which the key monitor requires.
private final class SidebarInputTestWindow: NSWindow {
    override var canBecomeKey: Bool {
        true
    }

    override var isKeyWindow: Bool {
        true
    }
}
