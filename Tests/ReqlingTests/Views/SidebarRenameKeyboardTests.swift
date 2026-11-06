import AppKit
import ReqlingKit
import SwiftUI
import XCTest

@testable import Reqling

/// Return and Escape as AppKit delivers them, against the real `List` beside another field: the key monitor only sees
/// events sent through `NSApp`, and only a neighbour proves Return elsewhere keeps working.
@MainActor
final class SidebarRenameKeyboardTests: XCTestCase {
    private var fixture: AppFixture!
    private var project: SnapshotProject!
    private var window: SidebarRenameTestWindow!
    private var controller: NSHostingController<AnyView>!

    override func setUp() async throws {
        fixture = AppFixture()
        project = try SnapshotProject.make(in: fixture)
        controller = NSHostingController(rootView: AnyView(
            HStack(spacing: 0) {
                SidebarView(model: fixture.model)
                    .frame(width: 280, height: 420)
                TextField("Neighbour", text: .constant(""))
                    .frame(width: 200)
            }
            .transaction { $0.animation = nil }
        ))
        let frame = NSRect(x: -3_000, y: -3_000, width: 480, height: 420)
        window = SidebarRenameTestWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setFrame(frame, display: false)
        window.orderFront(nil)
    }

    override func tearDown() async throws {
        closeSnapshotWindow(window, controller: controller)
        window = nil
        controller = nil
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
        let table = try await focusSidebar(selecting: .node(project.id, project.listUsers), expectsMonitor: false)

        try sendKey()
        settle()

        XCTAssertNil(fixture.model.renaming)
        XCTAssertTrue(window.firstResponder === table)
    }

    func testCommittedNamesAreTrimmedAndBlankOrUnchangedOnesKeepTheOldName() {
        XCTAssertEqual(InlineRenameField.committedName("  Users ", replacing: "List users"), "Users")
        XCTAssertNil(InlineRenameField.committedName("   ", replacing: "List users"))
        XCTAssertNil(InlineRenameField.committedName(" List users ", replacing: "List users"))
    }

    // MARK: - Helpers

    /// Selects `item` and gives the sidebar's table the keyboard, as a click on the row would.
    private func focusSidebar(selecting item: SidebarItem, expectsMonitor: Bool = true) async throws -> NSTableView {
        fixture.model.selection = item
        settle()
        let table = try XCTUnwrap(descendants(of: NSTableView.self).first)
        XCTAssertTrue(window.makeFirstResponder(table))
        if expectsMonitor {
            await waitUntil("the selected row's key monitor") {
                self.settle()
                return self.descendants(of: SidebarRenameKeyMonitorView.self).contains { $0.window === self.window }
            }
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
private final class SidebarRenameTestWindow: NSWindow {
    override var canBecomeKey: Bool {
        true
    }

    override var isKeyWindow: Bool {
        true
    }
}
