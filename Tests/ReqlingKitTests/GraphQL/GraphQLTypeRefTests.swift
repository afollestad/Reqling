import ReqlingKit
import XCTest

/// Which variables completion offers for an argument, per the spec's "Is Variable Usage Allowed".
final class GraphQLTypeRefTests: XCTestCase {
    func testAVariableMustBeAtLeastAsStrictAsWhereItGoes() {
        let id = GraphQLTypeRef.named("ID")
        let requiredID = GraphQLTypeRef.nonNull(id)

        XCTAssertTrue(requiredID.canBePassed(to: requiredID))
        XCTAssertTrue(requiredID.canBePassed(to: id))
        XCTAssertTrue(id.canBePassed(to: id))
        XCTAssertFalse(id.canBePassed(to: requiredID))
        XCTAssertTrue(id.canBePassed(to: requiredID, hasDefault: true))
        XCTAssertFalse(GraphQLTypeRef.named("String").canBePassed(to: id))
    }

    func testListsMustNestAlike() {
        let ids = GraphQLTypeRef.list(.nonNull(.named("ID")))

        XCTAssertTrue(GraphQLTypeRef.nonNull(ids).canBePassed(to: ids))
        XCTAssertTrue(ids.canBePassed(to: .list(.named("ID"))))
        XCTAssertFalse(GraphQLTypeRef.list(.named("ID")).canBePassed(to: ids))
        XCTAssertFalse(GraphQLTypeRef.named("ID").canBePassed(to: ids))
        XCTAssertFalse(ids.canBePassed(to: .named("ID")))
    }

    func testDescribesAndUnwrapsTypesAsGraphQLWritesThem() {
        let shelves = GraphQLTypeRef.nonNull(.list(.nonNull(.list(.nonNull(.named("String"))))))

        XCTAssertEqual(shelves.description, "[[String!]!]!")
        XCTAssertEqual(shelves.namedType, "String")
        XCTAssertEqual(shelves.nullable.description, "[[String!]!]")
        XCTAssertEqual(shelves.listElement?.description, "[String!]!")
        XCTAssertNil(GraphQLTypeRef.named("String").listElement)
    }
}
