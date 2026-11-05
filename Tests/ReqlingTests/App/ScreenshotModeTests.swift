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
