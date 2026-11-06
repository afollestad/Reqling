import ReqlingKit
import XCTest

@testable import Reqling

/// Screenshot mode only runs from `scripts/screenshots.sh`, so these keep its seeding from breaking unnoticed: each
/// scene opens its request with a cached run, on the tabs the website's captures show.
@MainActor
final class ScreenshotModeTests: XCTestCase {
    private var profile: AppStorageProfile!
    private var component: AppComponent!

    override func setUp() async throws {
        profile = AppStorageProfile.test()
        component = AppDI.makeTestComponent(storageProfile: profile)
    }

    override func tearDown() async throws {
        component.protoWorkspaces.retain(only: [])
        profile.cleanUp()
    }

    func testRequestSceneOpensTheGETWithItsJSONResponse() throws {
        try ScreenshotDemoProject.seed(.request, into: component)

        let editor = try XCTUnwrap(component.appModel.editor?.asHTTP)
        XCTAssertEqual(component.appModel.selectedNode()?.name, "Get user")
        XCTAssertEqual(editor.tab, .params)
        XCTAssertEqual(editor.response.tab, .body)
        XCTAssertEqual(editor.response.exchange?.response?.statusCode, 200)
    }

    func testBodySceneOpensThePOSTOnItsBodyAndTiming() throws {
        try ScreenshotDemoProject.seed(.body, into: component)

        let editor = try XCTUnwrap(component.appModel.editor?.asHTTP)
        XCTAssertEqual(component.appModel.selectedNode()?.name, "Create user")
        XCTAssertEqual(editor.tab, .body)
        XCTAssertEqual(editor.response.tab, .timing)
        XCTAssertNotNil(editor.response.exchange?.response?.timing)
    }

    /// The descriptor set it writes must load, or the method pickers show an error in the capture.
    func testGRPCSceneOpensTheStreamWithItsSchemaAndTimeline() async throws {
        try ScreenshotDemoProject.seed(.grpc, into: component)

        let editor = try XCTUnwrap(component.appModel.editor?.asGRPC)
        XCTAssertEqual(component.appModel.selectedNode()?.name, "Chat")
        XCTAssertEqual(editor.response.exchange?.grpc?.events.count, 4)
        await waitUntil("the schema to load") {
            if case .ready = editor.schema.status {
                return true
            }
            return false
        }
        XCTAssertNotNil(editor.schema.method(service: GreeterDescriptorSet.service, name: "Chat"))
    }

    /// The schema file it writes must load and accept the query, or the capture shows an error or an underline.
    func testGraphQLSceneOpensTheQueryWithItsSchemaInTheInspector() async throws {
        try ScreenshotDemoProject.seed(.graphql, into: component)

        let model = component.appModel
        let editor = try XCTUnwrap(model.editor?.asHTTP)
        let graphQL = try XCTUnwrap(editor.graphQL)
        await graphQL.settled()

        XCTAssertEqual(model.selectedNode()?.name, "Search products")
        XCTAssertEqual(editor.tab, .body)
        XCTAssertEqual(editor.response.exchange?.response?.statusCode, 200)
        guard case .ready(.file, _, nil) = graphQL.schema.status else {
            return XCTFail("\(graphQL.schema.status)")
        }
        XCTAssertEqual(graphQL.diagnostics.text, editor.spec.body.graphQL.query)
        XCTAssertEqual(graphQL.diagnostics.items, [])
        XCTAssertTrue(model.showsGraphQLSchema)
        XCTAssertEqual(graphQL.browser.currentType, "Product")
        XCTAssertNotNil(graphQL.schema.snapshot?.typeSystem.type(named: "Product"))
    }

    func testEventsSceneOpensTheStreamWithItsEvents() throws {
        try ScreenshotDemoProject.seed(.events, into: component)

        let editor = try XCTUnwrap(component.appModel.editor?.asHTTP)
        XCTAssertEqual(component.appModel.selectedNode()?.name, "Order updates")
        XCTAssertEqual(editor.tab, .headers)
        XCTAssertEqual(editor.response.exchange?.response?.eventStream?.entries.count, 3)
    }

    func testWebSocketSceneOpensTheConnectionWithItsTimeline() throws {
        try ScreenshotDemoProject.seed(.websocket, into: component)

        let editor = try XCTUnwrap(component.appModel.editor?.asWebSocket)
        XCTAssertEqual(component.appModel.selectedNode()?.name, "Support chat")
        XCTAssertEqual(editor.tab, .messages)
        XCTAssertEqual(editor.response.record?.close?.code, 1000)
        XCTAssertEqual(editor.response.record?.subprotocol, "chat.v2")
    }

    /// Storefront holds the GraphQL scene's request; every other scene keeps it collapsed, and only the live scenes
    /// add Acme API's Live folder, so neither changes another capture.
    func testOtherScenesKeepStorefrontCollapsedTheInspectorClosedAndNoLiveFolder() throws {
        try ScreenshotDemoProject.seed(.body, into: component)

        let library = component.projectLibrary
        let storefront = try XCTUnwrap(library.projects.first { $0.name == "Storefront" }?.id)
        let acme = try XCTUnwrap(library.projects.first { $0.name == "Acme API" }?.id)
        XCTAssertTrue(component.workspaceState.projectState(storefront).isCollapsed)
        XCTAssertFalse(component.appModel.isInspectorShown)
        XCTAssertEqual(library.document(acme)?.items.map(\.name), ["Users", "Orders", "Greeter", "Health check", "Purge cache"])
    }

    func testTheStorageIsWipedOnEveryLaunch() throws {
        let first = AppStorageProfile.screenshots()
        try FileManager.default.createDirectory(at: first.projectsDirectory, withIntermediateDirectories: true)
        first.settingsDefaults.set(true, forKey: "leftover")

        let second = AppStorageProfile.screenshots()
        defer { second.cleanUp() }

        XCTAssertTrue(second.isEphemeral)
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.projectsDirectory.path))
        XCTAssertNil(second.settingsDefaults.object(forKey: "leftover"))
    }
}
