import Foundation
@testable import ReqlingKit
import XCTest

/// Security schemes as auth on the project, a folder, or a request, with empty variables to fill in.
extension OpenAPIImporterTests {
    func testAuthSitsWhereEveryRequestBeneathSharesIt() async throws {
        let plan = try await petstore()
        guard case .folder(let store)? = node(plan, "store"), case .folder(let pets)? = node(plan, "pets") else {
            return XCTFail("tag folders")
        }

        XCTAssertEqual(plan.auth, .bearer(token: "{{bearerToken}}"), "The document's security")
        XCTAssertEqual(store.auth, .apiKey(name: "X-API-Key", value: "{{apiKey}}", location: .header))
        XCTAssertEqual(pets.auth, .inherit)
        XCTAssertEqual(try spec(plan, "pets", "List pets").auth, .inherit)
        XCTAssertEqual(try spec(plan, "pets", "deletePet").auth, .none, "security: [] means none")
        XCTAssertEqual(try spec(plan, "store", "Inventory").auth, .inherit)
        XCTAssertEqual(try spec(plan, "Who am I").auth, .bearer(token: "{{accessToken}}"))
    }

    func testCredentialsAreEmptySecretsInDefaultForSchemesInUse() async throws {
        let plan = try await petstore()
        let credentials = plan.defaultVariables.filter { plan.counts.credentialsToFill.contains($0.key) }

        XCTAssertEqual(Set(plan.counts.credentialsToFill), ["apiKey", "bearerToken", "accessToken"])
        XCTAssertTrue(credentials.allSatisfy { $0.isSecret && $0.value.isEmpty })
        XCTAssertTrue(messages(plan, .project).contains(
            "The “petstore_auth” scheme uses OAuth 2.0 (authorization code), which Reqling doesn't run; get a token from "
                + "https://petstore.example.com/oauth/token and put it in {{accessToken}}."
        ))
    }

    func testRequirementsPickTheFirstThatMapsAndExtraKeysBecomeRows() async throws {
        let plan = try await plan("""
        openapi: 3.0.3
        info: {title: Keys, version: '1'}
        paths:
          /both:
            get:
              summary: Both
              security: [{digest: []}, {basic: [], key: []}]
              responses: {}
          /users/{username}.json:
            get:
              summary: User
              security: [{basic: []}]
              parameters: [{name: username, in: path, required: true, schema: {type: string}}]
              responses: {}
          /cookie:
            get:
              summary: Cookie
              security: [{cookie: []}]
              responses: {}
        components:
          securitySchemes:
            digest: {type: http, scheme: digest}
            basic: {type: http, scheme: basic}
            key: {type: apiKey, in: query, name: key}
            cookie: {type: apiKey, in: cookie, name: session}
        """)
        let both = try spec(plan, "Both")

        XCTAssertEqual(plan.auth, .none, "No security of its own, and none every request shares")
        XCTAssertEqual(both.auth, .basic(username: "{{username}}", password: "{{password}}"), "Digest can't be met; basic can")
        XCTAssertEqual(both.queryParameters.map { "\($0.key)=\($0.value)" }, ["key={{apiKey}}"])
        XCTAssertEqual(try spec(plan, "Cookie").auth, .inherit, "None, as the project has")
        XCTAssertEqual(plan.defaultVariables.first { $0.key == "username" }?.isSecret, false)
        XCTAssertTrue(messages(plan, .node(["Cookie"])).contains("None of its security requirements can be met with Reqling's auth, so it has none."))
        let keys = plan.defaultVariables.map(\.key)
        XCTAssertEqual(keys.count, Set(keys).count, "\(keys)")
    }

    func testDeprecatedSchemesComeLastAndRequirementsPassedOverMakeNoVariables() async throws {
        let plan = try await plan("""
        openapi: 3.2.0
        info: {title: Choices, version: '1'}
        paths:
          /first:
            get:
              summary: First
              security: [{cookie: [], basic: []}, {legacy: []}, {token: []}]
              responses: {}
          /only:
            get:
              summary: Only
              security: [{cookie: []}, {legacy: []}]
              responses: {}
        components:
          securitySchemes:
            cookie: {type: apiKey, in: cookie, name: session}
            basic: {type: http, scheme: basic}
            legacy: {type: apiKey, in: header, name: X-Legacy-Key, deprecated: true}
            token: {type: http, scheme: bearer}
        """)

        XCTAssertEqual(try spec(plan, "First").auth, .bearer(token: "{{bearerToken}}"), "Past the cookie key and the deprecated one")
        XCTAssertEqual(try spec(plan, "Only").auth, .apiKey(name: "X-Legacy-Key", value: "{{apiKey}}", location: .header),
                       "Deprecated, but the only one it can meet")
        XCTAssertEqual(plan.counts.credentialsToFill, ["bearerToken", "apiKey"], "None for the basic scheme beside the cookie key")
    }
}
