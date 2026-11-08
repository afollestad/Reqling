import Foundation
import ReqlingKit
import ReqlingScriptProtocol
import XCTest

@testable import Reqling

/// The snippet menu above the script: what it offers for the shown phase and owner, and adding one without an editor.
@MainActor
extension ScriptsEditingTests {
    func testTheSnippetMenuFollowsThePhaseShownAndTheOwnersKind() throws {
        let scripts = try openRequest()
        XCTAssertEqual(scripts.snippetMenu, ScriptSnippets.menu(for: .preRequest, kind: .http))

        scripts.phase = .postResponse
        XCTAssertEqual(scripts.snippetMenu, ScriptSnippets.menu(for: .postResponse, kind: .http))
        XCTAssertTrue(scripts.snippetMenu.byProtocol.isEmpty)

        fixture.model.selection = .node(project, folder.id)
        let folderScripts = try XCTUnwrap(fixture.model.containerScripts?.scripts)
        folderScripts.phase = .postResponse
        XCTAssertEqual(folderScripts.snippetMenu, ScriptSnippets.menu(for: .postResponse, kind: nil))
        XCTAssertEqual(folderScripts.snippetMenu.byProtocol.map(\.kind), [.http, .grpc, .webSocket], "A folder's script serves every kind")
    }

    func testASnippetAddedWithoutAnEditorGoesOnItsOwnLineAfterTheScriptAndSaves() async throws {
        let scripts = try openRequest()
        scripts.source = "const a = 1"
        let set = try XCTUnwrap(scripts.snippetMenu.sections.first?.snippets.first)

        scripts.appendSnippet(set)
        await releaseAutosave()
        await waitUntil("the save") { self.stored?.scripts.preRequest.hasSuffix(set.code) == true }

        XCTAssertEqual(scripts.source, "const a = 1\n" + set.code)
    }
}
