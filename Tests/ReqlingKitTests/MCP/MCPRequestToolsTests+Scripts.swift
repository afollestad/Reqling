import Foundation
import MCP
@testable import ReqlingKit
import XCTest

extension MCPRequestToolsTests {
    func testRequestsCarryScriptsThatUpdatesChangeOneAtATime() async throws {
        let created = try await fixture.success("create_request", [
            "project": projectArgument,
            "name": "Login",
            "scripts": ["preRequest": "pre();", "postResponse": "post();"],
            "inheritScripts": false
        ])
        let id = try XCTUnwrap(created["request"]?["id"]?.stringValue)

        let fetched = try await fixture.success("get_request", ["project": projectArgument, "request": .string(id)])
        _ = try await fixture.success("update_request", ["project": projectArgument, "request": .string(id), "scripts": ["preRequest": ""]])
        let unknown = await fixture.failure("update_request", [
            "project": projectArgument,
            "request": .string(id),
            "scripts": ["tests": "x"]
        ])

        XCTAssertEqual(fetched["request"]?["scripts"], ["preRequest": "pre();", "postResponse": "post();"])
        XCTAssertEqual(fetched["request"]?["inheritScripts"], false)
        let request = try XCTUnwrap(try fixture.document(project).request(XCTUnwrap(RequestNodeID(string: id))))
        XCTAssertEqual(request.scripts, ScriptSet(preRequest: "", postResponse: "post();"))
        XCTAssertFalse(request.runsInheritedScripts)
        XCTAssertFalse(fixture.storage.exists("requests/login.pre.js", in: project))
        XCTAssertEqual(try fixture.storage.contents("requests/login.post.js", in: project), "post();")
        XCTAssertTrue(unknown.contains("tests"), unknown)
    }

    func testFoldersAndTheProjectCarryScripts() async throws {
        let folder = try await fixture.success("create_folder", [
            "project": projectArgument,
            "name": "Users",
            "scripts": ["preRequest": "sign();"]
        ])
        let folderID = try XCTUnwrap(folder["folder"]?["id"]?.stringValue)
        _ = try await fixture.success("update_folder", ["project": projectArgument, "folder": .string(folderID), "inheritScripts": false])
        _ = try await fixture.success("update_project", ["project": projectArgument, "scripts": ["postResponse": "check();"]])

        let fetched = try await fixture.success("get_project", ["project": projectArgument])

        XCTAssertEqual(fetched["scripts"], ["preRequest": "", "postResponse": "check();"])
        let tree = try XCTUnwrap(fetched["items"]?.arrayValue?.first)
        XCTAssertEqual(tree["scripts"], ["preRequest": "sign();", "postResponse": ""])
        XCTAssertEqual(tree["inheritScripts"], false)
        XCTAssertEqual(try fixture.storage.contents("requests/users/_folder.pre.js", in: project), "sign();")
        XCTAssertEqual(try fixture.storage.contents("project.post.js", in: project), "check();")
    }

    /// Across projects a request's scripts are written beside its new file, and its old ones go to the Trash with it.
    func testMovingARequestIntoAnotherProjectCarriesItsScripts() async throws {
        let created = try await fixture.success("create_request", ["project": projectArgument, "name": "Ping", "scripts": ["preRequest": "p();"]])
        let id = try XCTUnwrap(created["request"]?["id"]?.stringValue)
        let web = try await fixture.makeProject("Web")

        _ = try await fixture.success("move_request", ["project": projectArgument, "request": .string(id), "destinationProject": "web"])

        XCTAssertEqual(try fixture.storage.contents("requests/ping.pre.js", in: web), "p();")
        XCTAssertEqual(fixture.storage.trashedNames(), ["ping.json", "ping.pre.js"])
    }
}

/// What agents learn about the scripts they write.
@MainActor
extension MCPRequestToolsTests {
    func testWritingAScriptReportsItsProblemsAndTheReferenceDescribesTheAPI() async throws {
        let project = try await fixture.makeProject()
        let created = try await fixture.success("create_request", [
            "project": .string(project.description),
            "name": "Scripted",
            "http": ["url": "https://api.test"],
            "scripts": ["preRequest": "rq.response.code\nrq.request.metadata", "postResponse": "rq.test('ok', () => {"]
        ])
        let clean = try await fixture.success("create_folder", [
            "project": .string(project.description),
            "name": "Clean",
            "scripts": ["preRequest": "rq.request.metadata.upsert('x', '1')"]
        ])
        let reference = try await fixture.success("get_script_reference")

        let problems = try XCTUnwrap(created["scriptProblems"])
        XCTAssertEqual(problems["preRequest"]?.arrayValue?.map { $0["message"] }, [
            "rq.response works only in stream and post-response scripts.",
            "rq.request.metadata applies only to gRPC requests."
        ])
        XCTAssertEqual(problems["preRequest"]?.arrayValue?.last?["line"], 2)
        XCTAssertEqual(problems["postResponse"]?.arrayValue?.first?["severity"], "error")
        XCTAssertNil(clean["scriptProblems"], "A folder's script runs for every protocol")
        XCTAssertTrue(reference["reference"]?.stringValue?.contains("### `Reqling`") ?? false)
    }
}
