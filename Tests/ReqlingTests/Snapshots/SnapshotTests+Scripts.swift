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
}
