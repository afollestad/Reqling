import Foundation
import ReqlingKit
import XCTest

@testable import Reqling

@MainActor
final class RequestEditorViewModelTests: XCTestCase {
    private var fixture: AppFixture!
    private var gate: SleepGate!
    private var project: ProjectID!

    override func setUp() async throws {
        let gate = SleepGate()
        self.gate = gate
        fixture = AppFixture(sleep: { _ in await gate.sleep() })
        fixture.model.createProject(named: "Editor")
        project = fixture.model.selection?.projectID
        try fixture.library.mutate(project) { document in
            document.defaultEnvironment.variables = [
                Variable(key: "base", value: "https://api.test"),
                Variable(key: "token", value: "s3cr3t", isSecret: true)
            ]
        }
        fixture.model.newRequest()
    }

    override func tearDown() async throws {
        gate.releaseAll()
        fixture.tearDown()
        fixture = nil
    }

    private var editor: RequestEditorViewModel {
        fixture.model.editor!.asHTTP!
    }

    private var savedSpec: HTTPRequestSpec? {
        fixture.library.document(project)?.request(editor.requestID)?.kind.httpSpec
    }

    /// Replaces the stored request the way MCP or a `git pull` would, then reports it as the window does.
    private func changeExternally(_ spec: HTTPRequestSpec) throws {
        let request = editor.requestID
        try fixture.library.mutate(project) { try $0.updateRequest(request) { $0.kind = .http(spec) } }
        fixture.model.libraryDidChange()
    }

    /// Moves `project.json` aside and reloads, as when the folder is moved or mid-checkout; returns where it went.
    private func makeProjectUnavailable() throws -> (projectFile: URL, aside: URL) {
        let projectFile = try XCTUnwrap(fixture.library.project(project)?.url.appendingPathComponent("project.json"))
        let aside = fixture.profile.applicationSupportDirectory.appendingPathComponent("aside-project.json")
        try FileManager.default.moveItem(at: projectFile, to: aside)
        fixture.library.reload(project)
        fixture.model.libraryDidChange()
        return (projectFile, aside)
    }

    private func releaseAutosave() async {
        await waitUntil("the autosave to start waiting") { gate.pendingCount > 0 }
        gate.releaseAll()
    }

    func testEditsAutosaveOnlyAfterThePause() async throws {
        editor.urlText = "{{base}}/users?page=2"

        XCTAssertEqual(savedSpec?.url, "")
        await releaseAutosave()
        await waitUntil("the autosave") { savedSpec?.url == "{{base}}/users" }
        XCTAssertEqual(savedSpec?.queryParameters.unidentified, [KeyValuePair(key: "page", value: "2")].unidentified)
    }

    func testFlushSavesAPendingEditImmediately() {
        editor.spec.method = .post

        editor.flush()

        XCTAssertEqual(savedSpec?.method, .post)
    }

    func testTheURLBarKeepsTextTheSpecCannotShowUntilTheSpecChangesElsewhere() async throws {
        editor.urlText = "https://x/a?"
        XCTAssertEqual(editor.urlText, "https://x/a?")
        XCTAssertEqual(editor.spec.url, "https://x/a")

        editor.urlText = "https://x/a?a=1&b=2"
        editor.urlText = "https://x/a?a=&b=2"
        XCTAssertEqual(editor.spec.queryParameters.unidentified, [KeyValuePair(key: "a", value: ""), KeyValuePair(key: "b", value: "2")].unidentified)
        await releaseAutosave()
        await waitUntil("the autosave") { savedSpec?.queryParameters.count == 2 }
        XCTAssertEqual(editor.urlText, "https://x/a?a=&b=2", "saving must not rewrite what was typed")

        editor.spec.queryParameters[1].isEnabled = false
        XCTAssertEqual(editor.urlText, "https://x/a?a")
    }

    func testExternalChangesAreAdoptedOnlyWhileTheDraftIsClean() throws {
        try changeExternally(HTTPRequestSpec(url: "https://external"))
        XCTAssertEqual(editor.spec.url, "https://external")
        XCTAssertEqual(editor.urlText, "https://external")

        editor.spec.url = "https://local-edit"
        try changeExternally(HTTPRequestSpec(url: "https://external-2"))
        XCTAssertEqual(editor.spec.url, "https://local-edit")
    }

    func testAnExternalChangeDuringThePauseIsMergedIntoTheSave() async throws {
        editor.urlText = "https://local"
        try changeExternally(HTTPRequestSpec(headers: [KeyValuePair(key: "X-Agent", value: "1")]))
        XCTAssertEqual(editor.spec.url, "https://local")

        await releaseAutosave()
        await waitUntil("the merged save") { savedSpec?.url == "https://local" }

        XCTAssertEqual(savedSpec?.headers.unidentified, [KeyValuePair(key: "X-Agent", value: "1")].unidentified)
        XCTAssertEqual(editor.spec, savedSpec)
    }

    func testAHeaderRemovedElsewhereDuringThePauseStaysRemovedWhileTheUsersEditWins() async throws {
        let kept = KeyValuePair(key: "X-Kept", value: "1")
        try changeExternally(HTTPRequestSpec(headers: [kept, KeyValuePair(key: "X-Removed", value: "1")]))
        editor.spec.headers[0].value = "mine"
        try changeExternally(HTTPRequestSpec(headers: [
            KeyValuePair(id: kept.id, key: "X-Kept", value: "theirs"),
            KeyValuePair(key: "X-Added", value: "1")
        ]))

        await releaseAutosave()
        await waitUntil("the merged save") { savedSpec?.headers.first?.value == "mine" }

        XCTAssertEqual(savedSpec?.headers.map(\.key), ["X-Kept", "X-Added"])
        XCTAssertEqual(savedSpec?.headers.first?.id, kept.id)
        XCTAssertEqual(editor.spec, savedSpec)
    }

    /// The bar's text becomes rows on every keystroke; rows that survive keep their IDs, so a merge with an edit made
    /// elsewhere to another row keeps that edit instead of reading the keystroke as replacing every row.
    func testTypingInTheURLBarKeepsQueryRowIDsSoAMergeKeepsAnotherRowsEditElsewhere() async throws {
        editor.urlText = "https://x/a?page=1&size=10"
        editor.flush()
        let ids = editor.spec.queryParameters.map(\.id)

        editor.urlText = "https://x/a?page=12&size=10"
        XCTAssertEqual(editor.spec.queryParameters.map(\.id), ids)
        var external = try XCTUnwrap(savedSpec)
        external.queryParameters[1].value = "50"
        try changeExternally(external)
        await releaseAutosave()
        await waitUntil("the merged save") { savedSpec?.queryParameters.first?.value == "12" }

        XCTAssertEqual(savedSpec?.queryParameters.map(\.value), ["12", "50"])
        XCTAssertEqual(savedSpec?.queryParameters.map(\.id), ids)
        XCTAssertEqual(editor.urlText, "https://x/a?page=12&size=50")
    }

    func testAnUndoneEditStillAdoptsAnExternalChangeThatArrivedMeanwhile() async throws {
        editor.spec.method = .post
        try changeExternally(HTTPRequestSpec(url: "https://external"))
        editor.spec.method = .get
        XCTAssertEqual(editor.spec.url, "")

        await releaseAutosave()

        await waitUntil("the external change to be adopted") { editor.spec.url == "https://external" }
    }

    func testADraftOutlivesItsProjectBeingUnavailableAndSavesWhenItReturns() throws {
        let request = editor.requestID
        editor.spec.method = .post
        let (projectFile, aside) = try makeProjectUnavailable()

        editor.flush()

        XCTAssertNil(fixture.model.alert)
        XCTAssertEqual(fixture.model.selection, .node(project, request))
        XCTAssertEqual(editor.spec.method, .post)
        XCTAssertTrue(editor.isReadOnly)
        XCTAssertNotNil(editor.unavailableNote)
        XCTAssertEqual(editor.name, "New Request")

        try FileManager.default.moveItem(at: aside, to: projectFile)
        fixture.library.reload(project)
        fixture.model.libraryDidChange()
        XCTAssertEqual(editor.spec.method, .post, "adoption must never replace a dirty draft")
        XCTAssertEqual(savedSpec?.method, .get)

        editor.flush()

        XCTAssertEqual(savedSpec?.method, .post)
        XCTAssertNil(fixture.model.alert)
    }

    func testQuittingAsksBeforeLosingADraftStrandedByAnUnavailableProject() throws {
        XCTAssertTrue(fixture.model.confirmTermination())
        XCTAssertEqual(fixture.system.quitConfirmations, 0, "nothing to lose, so no question")

        editor.spec.method = .post
        _ = try makeProjectUnavailable()

        XCTAssertFalse(fixture.model.confirmTermination())
        XCTAssertEqual(fixture.system.quitConfirmations, 1)
        XCTAssertEqual(editor.spec.method, .post, "cancelling the quit keeps the draft")
        fixture.system.quitsDiscardingUnsavedChanges = true
        XCTAssertTrue(fixture.model.confirmTermination())
    }

    func testLeavingADraftStrandedByAnUnavailableProjectSaysItWasDiscarded() throws {
        editor.spec.method = .post
        _ = try makeProjectUnavailable()

        fixture.model.selection = .project(project)

        XCTAssertEqual(fixture.model.alert?.title, "Unsaved Changes Discarded")
    }

    func testADraftWhoseProjectReturnsReadOnlyIsDiscardedInsteadOfRetried() async throws {
        editor.spec.method = .post
        let (projectFile, aside) = try makeProjectUnavailable()
        editor.flush()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: aside)) as? [String: Any])
        json["formatVersion"] = ProjectDocument.currentFormatVersion + 1
        try JSONSerialization.data(withJSONObject: json).write(to: projectFile)

        fixture.library.reload(project)
        fixture.model.libraryDidChange()

        XCTAssertTrue(editor.isReadOnly)
        XCTAssertNil(editor.unavailableNote)
        XCTAssertEqual(editor.spec.method, .get, "the disabled editor shows what is stored")
        XCTAssertEqual(fixture.model.alert?.title, "Unsaved Changes Discarded")
        // Let the autosave `flush` cancelled reach the gate, so releasing it leaves only what was scheduled since.
        await waitUntil("the cancelled autosave to start waiting") { gate.pendingCount > 0 }
        gate.releaseAll()
        for _ in 0..<10 {
            await Task.yield()
        }
        XCTAssertEqual(gate.pendingCount, 0, "nothing may keep rescheduling a save")
    }

    func testTheMergeKeepsABodyModeSwitchAndARawTextEditedElsewhere() async throws {
        editor.spec.body.mode = .formData
        try changeExternally(HTTPRequestSpec(body: .raw("external")))

        await releaseAutosave()
        await waitUntil("the merged save") { savedSpec?.body.mode == .formData }

        XCTAssertEqual(savedSpec?.body.raw.text, "external")
    }

    func testAPendingEditToARequestDeletedElsewhereDropsWithoutAnAlert() throws {
        let request = editor.requestID
        editor.spec.method = .post

        try fixture.library.mutate(project) { try $0.removeNode(request) }
        fixture.model.libraryDidChange()

        XCTAssertEqual(fixture.model.selection, .project(project))
        XCTAssertNil(fixture.model.alert)
    }

    func testPastingCurlReplacesTheRequestAndReportsWarnings() {
        XCTAssertFalse(editor.importCurl("https://not-curl"))

        XCTAssertTrue(editor.importCurl("curl -X PUT https://x/upload -F file=@photo.png"))

        XCTAssertEqual(editor.spec.method, .put)
        XCTAssertEqual(editor.spec.body.mode, .formData)
        XCTAssertEqual(editor.urlText, "https://x/upload")
        XCTAssertEqual(editor.notice, "Choose the file for the “file” form field.")
    }

    func testCopyAsCurlUsesTheResolvedRequest() {
        editor.urlText = "{{base}}/me"
        editor.spec.headers = [KeyValuePair(key: "Authorization", value: "Bearer {{token}}")]

        editor.copyAsCurl()

        let command = fixture.system.pasteboard ?? ""
        XCTAssertTrue(command.contains("'https://api.test/me'"), command)
        XCTAssertTrue(command.contains("Bearer s3cr3t"), command)
    }

    func testTheTokenContextMasksSecretsAndCompletesNames() {
        let context = editor.tokenContext

        XCTAssertEqual(context.entries["token"]?.displayValue, TemplateResolver.mask)
        XCTAssertEqual(context.entries["base"]?.displayValue, "https://api.test")
        XCTAssertEqual(context.completions(matching: "b"), ["base"])
        XCTAssertEqual(Array(context.completions(matching: "").prefix(2)), ["base", "token"])
    }
}
