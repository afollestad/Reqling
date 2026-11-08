import Foundation
@testable import ReqlingKit
import XCTest

/// Postman's auth at every level, with literal credentials moved into secret variables.
extension PostmanImporterTests {
    func testAuthMapsWhereReqlingHasItsTypeAndCredentialsMoveToSecrets() throws {
        let plan = try petstore()
        guard case .folder(let auth)? = node(plan, "Auth") else {
            return XCTFail("Auth is a folder")
        }

        XCTAssertEqual(plan.auth, .apiKey(name: "X-API-Key", value: "{{apiKey}}", location: .header), "the collection's is the project's")
        XCTAssertEqual(auth.auth, .basic(username: "admin", password: "{{basicPassword}}"))
        XCTAssertEqual(try spec(plan, "Auth", "Login").auth, .none, "no auth stays none")
        XCTAssertEqual(try spec(plan, "Pets", "Get pet").auth, .inherit)
        XCTAssertEqual(try spec(plan, "Pets", "Search").auth, .bearer(token: "{{bearerToken}}"))
        XCTAssertEqual(plan.counts.credentials, ["apiKey", "basicPassword", "bearerToken"])
        let secrets = plan.defaultVariables.filter(\.isSecret)
        XCTAssertEqual(secrets.map(\.key), ["apiKey", "basicPassword", "bearerToken"])
        XCTAssertEqual(secrets.map(\.value), ["k-123", "hunter2", "abc123"])
    }

    /// An auth type Reqling lacks becomes none, not inherited, so a parent's other auth isn't sent in its place.
    func testAnAuthTypeReqlingLacksBecomesNoneWithANote() throws {
        let plan = try petstore()

        XCTAssertEqual(try spec(plan, "Pets", "Update pet").auth, .none)
        XCTAssertEqual(messages(plan, "Pets", "Update pet"), [
            "It used OAuth 2.0 auth, which Reqling doesn't have, so it has none; set it up yourself."
        ])
    }

    func testEqualCredentialsShareAVariableAndNamesInUseAreSkipped() throws {
        func bearer(_ name: String, _ token: String) -> String {
            #"{"name": "\#(name)", "request": {"url": "https://x", "auth": {"type": "bearer", "bearer": [{"key": "token", "value": "\#(token)"}]}}}"#
        }
        let plan = try self.plan(
            items: "[\(bearer("A", "one")), \(bearer("B", "one")), \(bearer("C", "two")), \(bearer("D", "{{token}}")), \(bearer("E", ""))]",
            extra: #""variable": [{"key": "bearerToken", "value": "taken"}]"#
        )

        XCTAssertEqual(try ["A", "B", "C", "D", "E"].map { try spec(plan, $0).auth }, [
            .bearer(token: "{{bearerToken2}}"), .bearer(token: "{{bearerToken2}}"), .bearer(token: "{{bearerToken3}}"),
            .bearer(token: "{{token}}"), .bearer(token: "")
        ])
        XCTAssertEqual(plan.defaultVariables.map(\.key), ["bearerToken", "bearerToken2", "bearerToken3"])
    }

    /// Collection v2.0 writes a type's attributes as one object rather than a list.
    func testVersion2AuthReadsTheSame() throws {
        let plan = try self.plan(items: """
        [{"name": "Old", "request": {"url": "https://x", "auth": {"type": "apikey", "apikey": {"key": "token", "value": "{{key}}", "in": "query"}}}}]
        """)

        XCTAssertEqual(try spec(plan, "Old").auth, .apiKey(name: "token", value: "{{key}}", location: .query))
    }
}
