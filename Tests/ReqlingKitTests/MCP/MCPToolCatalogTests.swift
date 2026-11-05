import Foundation
import MCP
@testable import ReqlingKit
import XCTest

@MainActor
final class MCPToolCatalogTests: XCTestCase {
    private var fixture: MCPFixture!

    override func setUp() async throws {
        fixture = try MCPFixture()
    }

    override func tearDown() async throws {
        fixture.cleanUp()
    }

    /// Some clients drop a tool whose schema root isn't a plain object; strict objects keep unadvertised fields out.
    func testEveryToolIsNamedDescribedAndTakesAStrictObject() throws {
        let tools = fixture.dispatcher.definitions
        XCTAssertEqual(Set(tools.map(\.name)).count, tools.count)
        for tool in tools {
            XCTAssertNotNil(tool.name.range(of: #"^[a-z][a-z_]*$"#, options: .regularExpression), tool.name)
            XCTAssertFalse(tool.title?.isEmpty ?? true, tool.name)
            XCTAssertFalse(tool.description?.isEmpty ?? true, tool.name)
            XCTAssertNotNil(tool.annotations.readOnlyHint, tool.name)
            let schema = try XCTUnwrap(tool.inputSchema.objectValue, tool.name)
            XCTAssertEqual(schema["type"], "object", tool.name)
            XCTAssertEqual(schema["additionalProperties"], false, tool.name)
            let properties = Set(schema["properties"]?.objectValue?.keys.map { $0 } ?? [])
            let required = Set(schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            XCTAssertTrue(required.isSubset(of: properties), "\(tool.name) requires an unlisted field")
        }
    }

    func testTheCatalogCoversEachArea() {
        let names = Set(fixture.dispatcher.definitions.map(\.name))
        for name in [
            "create_project", "list_projects", "delete_project", "create_variables", "list_variables", "update_variables",
            "delete_variables", "create_request", "list_requests", "update_request", "delete_request", "execute_request",
            "list_runs", "get_run", "clear_history", "compile_protos", "update_tls_config", "reveal_item", "update_settings"
        ] {
            XCTAssertTrue(names.contains(name), name)
        }
        XCTAssertFalse(names.contains { $0.contains("token") || $0.contains("mcp") }, "Agents never manage the server itself")
    }

    func testUnknownToolsAndFieldsAreRefused() async {
        let unknownTool = await fixture.failure("drop_tables")
        let unknownField = await fixture.failure("list_projects", ["verbose": true])
        let wrongType = await fixture.failure("get_project", ["project": 7])

        XCTAssertTrue(unknownTool.contains("no tool named drop_tables"), unknownTool)
        XCTAssertTrue(unknownField.contains("unsupported field(s): verbose"), unknownField)
        XCTAssertTrue(wrongType.contains("project must be a string"), wrongType)
    }

    func testAToolThatOutlivesItsTimeoutIsStopped() async {
        let dispatcher = MCPToolDispatcher(
            tools: [MCPTool("wait", title: "Wait", description: "Waits.", annotations: .read, timeout: .seconds(5)) { _ in
                try await Task.sleep(for: .seconds(3_600))
                return .object([:])
            }],
            sleep: { _ in }
        )

        let result = await dispatcher.call("wait", arguments: nil)

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("didn't finish within 5 seconds"), result.text)
    }

    func testOversizedOutputBecomesAnError() async {
        let dispatcher = MCPToolDispatcher(tools: [MCPTool("dump", title: "Dump", description: "Dumps.", annotations: .read) { _ in
            .object(["data": .string(String(repeating: "x", count: MCPToolDispatcher.outputLimit))])
        }])

        let result = await dispatcher.call("dump", arguments: nil)

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("larger than Reqling returns"), result.text)
    }
}
