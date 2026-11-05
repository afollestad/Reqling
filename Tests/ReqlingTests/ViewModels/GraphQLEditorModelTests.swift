import Foundation
import ReqlingKit
import XCTest

@testable import Reqling

/// A GraphQL request's editor: its schema loads from a file in the project (app graphs never introspect), its query is
/// checked against it, and only what changes how the schema is asked for reloads it.
@MainActor
final class GraphQLEditorModelTests: XCTestCase {
    private var fixture: AppFixture!
    private var gate: SleepGate!
    private var sleeps: SleepSwitch!
    private var project: ProjectID!

    override func setUp() async throws {
        let gate = SleepGate()
        let sleeps = SleepSwitch()
        self.gate = gate
        self.sleeps = sleeps
        fixture = AppFixture(sleep: { _ in
            if await sleeps.holds {
                await gate.sleep()
            }
        })
        fixture.model.createProject(named: "GraphQL")
        project = fixture.model.selection?.projectID
        let staging = RequestEnvironment(name: "Staging", variables: [Variable(key: "base", value: "https://staging.test")])
        try fixture.library.mutate(project) { document in
            document.defaultEnvironment.variables = [Variable(key: "base", value: "https://api.test")]
            document.environments.append(staging)
        }
        let folder = try XCTUnwrap(fixture.library.project(project)?.url)
        try Self.sdl.write(to: folder.appendingPathComponent("api.graphql"), atomically: true, encoding: .utf8)
        fixture.model.newRequest()
        editor.spec = HTTPRequestSpec(
            method: .post,
            url: "{{base}}/graphql",
            body: HTTPBody(mode: .graphQL, graphQL: GraphQLBody(query: "{ me { name } }", schema: .file(.relative("api.graphql"))))
        )
        await waitForSchema()
    }

    override func tearDown() async throws {
        gate.releaseAll()
        fixture.tearDown()
        fixture = nil
    }

    private var editor: RequestEditorViewModel {
        fixture.model.editor!.asHTTP!
    }

    private var model: GraphQLEditorModel {
        editor.graphQL!
    }

    private var saved: HTTPRequestSpec? {
        fixture.library.document(project)?.request(editor.requestID)?.kind.httpSpec
    }

    static let sdl = """
        type Query { me: Author, ping: String! }
        type Author { name: String!, nickname: String @deprecated(reason: "Use name.") }
        """

    // MARK: - Lifecycle

    func testTheSchemaComesFromTheRequestsFile() {
        guard case .ready(.file(let name), let typeCount, nil) = model.schema.status else {
            return XCTFail("\(model.schema.status)")
        }
        XCTAssertEqual(name, "api.graphql")
        XCTAssertEqual(typeCount, 4, "Query, Author, String, and Boolean")
        XCTAssertEqual(model.completions(in: "{ me { na", cursor: 9)?.items.map(\.label), ["name", "__typename", "nickname"])
        XCTAssertEqual(model.hover(in: "{ me { name } }", at: 8)?.signature, "Author.name: String!")
    }

    func testOnlyARequestThatSendsAGraphQLBodyHasTheModel() {
        editor.setMethod(.get)
        XCTAssertNil(editor.graphQL, "a GET sends no body")
        editor.setMethod(.post)
        XCTAssertNotNil(editor.graphQL)
        editor.spec.body.mode = .raw
        XCTAssertNil(editor.graphQL)
    }

    func testIntrospectionNeedsAURLAndNeverReachesTheNetworkHere() async {
        editor.spec.body.graphQL.schema = .introspection
        editor.spec.url = ""
        await model.settled()
        XCTAssertEqual(model.schema.status, .idle("Enter the URL to read its schema by introspection, or choose a schema file."))

        editor.spec.url = "https://api.test/graphql"
        await model.settled()

        guard case .failed(let message) = model.schema.status else {
            return XCTFail("\(model.schema.status)")
        }
        XCTAssertTrue(message.contains("Introspection is turned off"), message)
    }

    // MARK: - Checking

    func testProblemsAreFoundOnceTypingPausesAndStampedWithTheirQuery() async {
        editor.spec.body.graphQL.query = "{ me { nmae } }"

        await model.settled()

        XCTAssertEqual(model.diagnostics.text, "{ me { nmae } }")
        XCTAssertEqual(model.diagnostics.items.map(\.range), [NSRange(location: 7, length: 4)])
        XCTAssertEqual(model.diagnostics.items.first?.severity, .error)
    }

    func testANewerCheckSupersedesAnOlderOne() async {
        sleeps.holds = true
        editor.spec.body.graphQL.query = "{ me { nmae } }"
        editor.spec.body.graphQL.query = "{ me { nickname } }"

        await waitUntil("both checks to wait") { gate.pendingCount >= 2 }
        sleeps.holds = false
        gate.releaseAll()
        await model.settled()

        XCTAssertEqual(model.diagnostics.text, "{ me { nickname } }")
        XCTAssertEqual(model.diagnostics.items.map(\.severity), [.warning])
    }

    // MARK: - Reloading

    func testEditingTheQueryNeverReloadsTheSchema() async {
        let loaded = model.schema.snapshot?.id
        var loads = 0
        model.schema.prepare = { [weak editor] in
            loads += 1
            editor?.flush()
        }

        editor.spec.body.graphQL.query = "{ ping }"
        editor.spec.body.graphQL.variables = #"{"a": 1}"#
        editor.spec.body.graphQL.operationName = "Ping"
        await model.settled()

        XCTAssertEqual(loads, 0)
        XCTAssertEqual(model.schema.snapshot?.id, loaded)
    }

    func testAnotherURLOrEnvironmentReloadsButASaveDoesNot() async throws {
        var loads = 0
        model.schema.prepare = { [weak editor] in
            loads += 1
            editor?.flush()
        }

        editor.spec.url = "{{base}}/v2/graphql"
        await model.settled()
        XCTAssertEqual(loads, 1, "a reload for the URL")
        let staging = try XCTUnwrap(fixture.library.document(project)?.environments.first { $0.name == "Staging" }?.id)
        fixture.model.setActiveEnvironment(staging, for: project)
        await waitUntil("the environment switch to be seen") { loads == 2 }
        await model.settled()
        editor.spec.body.graphQL.query = "{ me { name nickname } }"
        editor.flush()
        await model.settled()

        XCTAssertEqual(loads, 2, "saving the query reloads nothing")
    }

    /// A schema read elsewhere (MCP's GraphQL tools go through the runner) reaches the open editor without a reload of
    /// its own: the service's revision changes, and the editor loads again quietly.
    func testASchemaReadElsewhereReachesTheEditor() async throws {
        var loads = 0
        model.schema.prepare = { [weak editor] in
            loads += 1
            editor?.flush()
        }
        let folder = try XCTUnwrap(fixture.library.project(project)?.url)
        try (Self.sdl + "\ntype Extra { id: ID }").write(to: folder.appendingPathComponent("api.graphql"), atomically: true, encoding: .utf8)

        _ = try await fixture.model.runner.graphQLSchema(for: editor.requestID, in: project, refresh: false)
        await waitUntil("the editor to load again") { loads == 1 }
        await model.settled()

        XCTAssertNotNil(model.schema.snapshot?.typeSystem.type(named: "Extra"))
        guard case .ready(.file, 6, nil) = model.schema.status else {
            return XCTFail("\(model.schema.status)")
        }
        XCTAssertEqual(loads, 1, "the editor's reload hits the cache, so it starts no other")
    }

    // MARK: - Editing

    /// A schema source chosen elsewhere (an agent, a pull) during the autosave pause survives an edit to the query
    /// here: the merged save keeps both.
    func testTheMergedSaveKeepsASchemaSourceChosenElsewhere() async throws {
        sleeps.holds = true
        editor.spec.body.graphQL.query = "{ ping }"
        let request = editor.requestID
        var external = try XCTUnwrap(fixture.library.document(project)?.request(request)?.kind.httpSpec)
        external.body.graphQL.schema = .introspection
        try fixture.library.mutate(project) { try $0.updateRequest(request) { $0.kind = .http(external) } }
        fixture.model.libraryDidChange()

        await waitUntil("the autosave to wait") { gate.pendingCount > 0 }
        sleeps.holds = false
        gate.releaseAll()
        await waitUntil("the merged save") { saved?.body.graphQL.query == "{ ping }" }

        XCTAssertEqual(saved?.body.graphQL.schema, .introspection)
        XCTAssertEqual(editor.spec.body.graphQL.schema, .introspection)
    }

    func testChoosingASchemaFileUsesIt() throws {
        editor.spec.body.graphQL.schema = .introspection
        let folder = try XCTUnwrap(fixture.library.project(project)?.url)
        fixture.system.fileToChoose = folder.appendingPathComponent("api.graphql")

        editor.chooseGraphQLSchemaFile()

        XCTAssertEqual(editor.spec.body.graphQL.schema, .file(.relative("api.graphql")))
        XCTAssertEqual(editor.graphQLSchemaSourceTitle, "api.graphql")
    }

    // MARK: - Inspector

    func testTheSchemaAndTheHistoryShareTheInspector() {
        let app = fixture.model

        app.toggleGraphQLSchema()
        XCTAssertTrue(app.showsGraphQLSchema)
        XCTAssertTrue(editor.isShowingGraphQLSchema)
        app.toggleRunHistory()
        XCTAssertTrue(app.showsRunHistory, "the history takes the open inspector")
        XCTAssertFalse(app.showsGraphQLSchema)
        app.toggleRunHistory()
        XCTAssertFalse(app.isInspectorShown, "asking for what already shows closes it")

        editor.isShowingGraphQLSchema = true
        editor.spec.body.mode = .raw
        XCTAssertTrue(app.showsRunHistory, "a request with no GraphQL body shows its history")
        editor.spec.body.mode = .graphQL
        XCTAssertTrue(app.showsGraphQLSchema, "and the schema again once it has one")
    }

    /// The toolbar's inspector toggle keeps whichever panel is open; the commands that name a panel switch to it.
    func testTheInspectorToggleKeepsItsPanel() {
        let app = fixture.model

        app.toggleGraphQLSchema()
        app.toggleInspector()
        XCTAssertFalse(app.isInspectorShown, "it closes from the schema")
        app.toggleInspector()
        XCTAssertTrue(app.showsGraphQLSchema, "and reopens on it")
        app.toggleRunHistory()
        XCTAssertTrue(app.showsRunHistory, "⌘Y still switches to the history")

        editor.isShowingGraphQLSchema = true
        editor.spec.body.mode = .raw
        app.toggleInspector()
        XCTAssertFalse(app.isInspectorShown)
        app.toggleInspector()
        XCTAssertTrue(app.showsRunHistory, "a request with no schema opens on its history")
    }

    func testTheBrowserListsRootsFirstThenKindsAndFollowsTypes() throws {
        let snapshot = try XCTUnwrap(model.schema.snapshot)
        let browser = model.browser

        XCTAssertEqual(browser.sections(in: snapshot).map(\.title), ["Roots", "Objects", "Scalars"])
        XCTAssertEqual(browser.sections(in: snapshot).first?.entries.map(\.type), ["Query"])
        browser.filter = "nick"
        XCTAssertEqual(browser.sections(in: snapshot).map(\.title), ["Fields"])
        XCTAssertEqual(browser.sections(in: snapshot).first?.entries.first?.id, "Author.nickname")

        browser.show("Author")
        XCTAssertEqual(browser.filter, "", "opening a type clears the filter")
        browser.show("String")
        XCTAssertEqual(browser.path, ["Author", "String"])
        browser.back()
        XCTAssertEqual(browser.currentType, "Author")
    }

    // MARK: - Support

    /// Whether sleeps wait for the gate; off, the pauses pass at once.
    @MainActor
    private final class SleepSwitch {
        var holds = false
    }

    /// Waits twice: a load that reads the file changes the service's revision, which starts one quiet reload after it
    /// (a cache hit), so each test starts with nothing in flight.
    private func waitForSchema() async {
        await editor.graphQL?.settled()
        await editor.graphQL?.settled()
        guard case .ready = editor.graphQL?.schema.status else {
            return XCTFail("No schema: \(String(describing: editor.graphQL?.schema.status))")
        }
    }
}
