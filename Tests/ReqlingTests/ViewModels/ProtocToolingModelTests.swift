import Foundation
import ReqlingKit
import XCTest

@testable import Reqling

@MainActor
final class ProtocToolingModelTests: XCTestCase {
    private var fixture: AppFixture!

    override func setUp() async throws {
        fixture = AppFixture(protocInstaller: StubProtocInstaller(phases: [
            .downloading(receivedBytes: 1_000, expectedBytes: 4_000),
            .verifying
        ]))
    }

    override func tearDown() async throws {
        fixture.protoc.installer.finish(.failure(.httpStatus(500)))
        fixture.tearDown()
        fixture = nil
    }

    private var protoc: ProtocToolingFixture {
        fixture.protoc
    }

    private var model: ProtocToolingModel {
        fixture.protoc.model
    }

    func testRefreshReportsTheFoundProtoc() async {
        protoc.locator.result = .success(ProtocFixtures.homebrew)
        XCTAssertEqual(model.detection, .unknown)

        await model.refresh()

        XCTAssertEqual(model.detection, .found(ProtocFixtures.homebrew))
        XCTAssertFalse(model.hasCurrentManagedInstall)
    }

    func testRefreshReportsAMissingProtoc() async {
        await model.refresh()

        XCTAssertEqual(model.detection, .missing)
        XCTAssertEqual(protoc.locator.overridePaths, [nil])
    }

    func testABrokenOverrideIsReportedRatherThanMissing() async {
        let error = StubLocateError(message: "The protoc set in Settings (/nope/protoc) does not exist or is not executable.")
        protoc.locator.result = .failure(error)

        await model.refresh()

        XCTAssertEqual(model.detection, .invalidOverride(error.localizedDescription))
    }

    func testCommittingTheOverrideSavesItRecompilesAndSearchesWithIt() async {
        model.overridePathDraft = "  /usr/local/opt/protoc  "

        model.commitOverridePath()

        XCTAssertEqual(fixture.component.settingsStore.settings.protocPath, "/usr/local/opt/protoc")
        XCTAssertEqual(model.overridePathDraft, "/usr/local/opt/protoc")
        XCTAssertEqual(protoc.recompileCount, 1)
        await waitUntil("the search with the override") { protoc.locator.overridePaths == ["/usr/local/opt/protoc"] }

        // Committing the same path again (leaving the field, say) changes nothing.
        model.commitOverridePath()
        XCTAssertEqual(protoc.recompileCount, 1)

        model.clearOverridePath()
        XCTAssertNil(fixture.component.settingsStore.settings.protocPath)
        XCTAssertEqual(protoc.recompileCount, 2)
    }

    func testChoosingAnOverrideSavesTheChosenFile() {
        fixture.system.fileToChoose = URL(fileURLWithPath: "/opt/tools/protoc")

        model.chooseOverridePath()

        XCTAssertEqual(fixture.component.settingsStore.settings.protocPath, "/opt/tools/protoc")
        XCTAssertEqual(protoc.recompileCount, 1)
    }

    func testInstallingShowsEachPhaseThenRecompilesAndFindsTheNewInstall() async {
        model.install()
        XCTAssertTrue(model.isInstalling)
        await waitUntil("the verifying phase") { model.installState == .installing(.verifying) }
        // A second click while installing does not start another.
        model.install()
        XCTAssertEqual(protoc.installer.installCount, 1)
        XCTAssertEqual(protoc.recompileCount, 0)

        protoc.locator.result = .success(ProtocFixtures.managed)
        protoc.installer.finish(.success(ProtocFixtures.managed))

        await waitUntil("the install to finish") { model.installState == .idle }
        XCTAssertEqual(protoc.recompileCount, 1)
        await waitUntil("the search after installing") { model.detection == .found(ProtocFixtures.managed) }
        XCTAssertTrue(model.hasCurrentManagedInstall)
    }

    func testAFailedInstallReportsWhyAndRecompilesNothing() async {
        model.install()
        await waitUntil("the installer to start") { protoc.installer.isWaiting }

        protoc.installer.finish(.failure(.digestMismatch(expected: "a", actual: "b")))

        await waitUntil("the failure") { !model.isInstalling }
        XCTAssertEqual(model.installState, .failed(ProtocInstallError.digestMismatch(expected: "a", actual: "b").localizedDescription))
        XCTAssertEqual(protoc.recompileCount, 0)
        XCTAssertEqual(model.detection, .unknown)
    }

    func testCancellingAnInstallReturnsToIdleWithoutRecompiling() async {
        model.install()
        await waitUntil("the installer to start") { protoc.installer.isWaiting }

        model.cancelInstall()

        await waitUntil("the cancellation") { model.installState == .idle }
        XCTAssertTrue(protoc.installer.wasCancelled)
        XCTAssertEqual(protoc.recompileCount, 0)
        XCTAssertEqual(model.detection, .unknown)
    }
}
