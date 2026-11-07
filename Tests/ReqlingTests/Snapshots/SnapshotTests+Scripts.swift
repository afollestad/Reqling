import ReqlingKit
import SwiftUI
import XCTest

@testable import Reqling

/// The Scripts tab and a folder's scripts: the phase picker, the inherit toggle, the levels that run first, and
/// JavaScript highlighting.
extension SnapshotTests {
    private func scriptedProject() throws -> (SnapshotProject, purgeCache: RequestNodeID) {
        let project = try SnapshotProject.make(in: fixture)
        let document = try XCTUnwrap(fixture.library.document(project.id))
        let purgeCache = try XCTUnwrap(document.folder(project.folder)?.children.first?.id)
        try fixture.library.mutate(project.id) { document in
            document.scripts.preRequest = "rq.request.headers.upsert(\"X-Client\", \"reqling\")"
            try document.updateFolder(project.folder) { $0.scripts.preRequest = "// Admin requests need a fresh token." }
            try document.updateRequest(purgeCache) { request in
                request.scripts.preRequest = """
                // Signs the request with a timestamped HMAC.
                const timestamp = Date.now().toString()
                const signature = rq.crypto.hmac("sha256", rq.environment.get("token"), timestamp)
                rq.request.headers.upsert("X-Timestamp", timestamp)
                rq.request.headers.upsert("X-Signature", signature)
                """
            }
        }
        return (project, purgeCache)
    }

    func testEditorScriptsTab() throws {
        let (project, purgeCache) = try scriptedProject()
        fixture.model.selection = .node(project.id, purgeCache)
        let editor = try XCTUnwrap(fixture.model.editor?.asHTTP)
        editor.tab = .scripts

        assertBothAppearances(RequestEditorPane(editor: editor, model: fixture.model), size: CGSize(width: 920, height: 380))
    }

    /// Requests and folders with scripts of their own are marked; the project's own scripts mark nothing.
    func testSidebarMarksItemsWithScripts() throws {
        _ = try scriptedProject()

        assertBothAppearances(SidebarView(model: fixture.model), size: CGSize(width: 280, height: 360))
    }

    func testFolderDetailScripts() throws {
        let (project, _) = try scriptedProject()
        fixture.model.selection = .node(project.id, project.folder)
        let folder = try XCTUnwrap(fixture.library.document(project.id)?.folder(project.folder))

        assertBothAppearances(FolderDetailView(folder: folder, projectID: project.id, model: fixture.model), size: CGSize(width: 820, height: 720))
    }

    /// A script's suggestions: members by kind, a variable name in a string, and a key from the latest response.
    func testScriptCompletionList() {
        assertBothAppearances(CodeCompletionListView(model: Self.scriptCompletions(highlighted: 0)).padding(8), size: CGSize(width: 396, height: 180))
    }

    /// The highlighted key's path in the latest response, described beneath the list as every suggestion is.
    func testScriptCompletionListDescribesKeys() {
        assertBothAppearances(CodeCompletionListView(model: Self.scriptCompletions(highlighted: 4)).padding(8), size: CGSize(width: 396, height: 180))
    }

    private static func scriptCompletions(highlighted: Int) -> CodeCompletionModel {
        let model = CodeCompletionModel()
        model.items = [
            CodeCompletionItem(id: 0, label: "response", kind: .namespace, detail: "Response", summary: "What came back.",
                               isDeprecated: false, insertText: "response"),
            CodeCompletionItem(id: 1, label: "test", kind: .method, detail: "(name, callback) → void",
                               summary: "Runs a named test; it fails when the callback throws or its promise rejects.",
                               isDeprecated: false, insertText: "test"),
            CodeCompletionItem(id: 2, label: "code", kind: .property, detail: "number", summary: "The status code.",
                               isDeprecated: false, insertText: "code"),
            CodeCompletionItem(id: 3, label: "token", kind: .scriptVariable, detail: nil, summary: "In Staging and Global.",
                               isDeprecated: false, insertText: "token"),
            CodeCompletionItem(id: 4, label: "users", kind: .jsonKey, detail: "array", summary: "data.users in the latest response's JSON.",
                               isDeprecated: false, insertText: "users"),
            CodeCompletionItem(id: 5, label: "signature", kind: .local, detail: nil, summary: "Declared in this script.",
                               isDeprecated: false, insertText: "signature")
        ]
        model.highlighted = highlighted
        return model
    }

    /// A Postman name describes itself and its Reqling equivalent.
    func testPostmanHoverCard() {
        let content = CodeHoverCardContent(
            hover: CodeHoverContent(
                range: NSRange(location: 3, length: 11),
                signature: "Postman.environment: PostmanEnvironment",
                summary: "The active environment's variables.\n\nFor scripts from Postman. Reqling's own is rq.environment.",
                deprecationReason: nil
            ),
            diagnostics: []
        )

        assertBothAppearances(CodeHoverCard(content: content).padding(8), size: CGSize(width: 340, height: 140))
    }
}
