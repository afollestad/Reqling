import XCTest

@testable import Reqling

@MainActor
final class AppDITests: XCTestCase {
    func testTestComponentUsesTheGivenStorage() {
        let profile = AppStorageProfile.test()
        defer { profile.cleanUp() }

        // Building the component exercises the generated Needle provider registration, which traps
        // when the committed `NeedleGenerated.swift` no longer matches the component graph.
        let component = AppDI.makeTestComponent(storageProfile: profile)

        XCTAssertEqual(component.storageProfile.applicationSupportDirectory, profile.applicationSupportDirectory)
    }
}
