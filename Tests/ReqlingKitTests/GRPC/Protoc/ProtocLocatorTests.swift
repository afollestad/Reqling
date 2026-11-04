import Foundation
@testable import ReqlingKit
import XCTest

final class ProtocLocatorTests: XCTestCase {
    private let tools = URL(fileURLWithPath: "/fake/Tools", isDirectory: true)
    private let managed = "/fake/Tools/protoc/36.2/bin/protoc"
    private let homebrew = "/opt/homebrew/bin/protoc"
    private let usrLocal = "/usr/local/bin/protoc"
    private let onPath = "/custom/bin/protoc"
    private let override = "/settings/protoc"

    func testEachSourceWinsOnlyWhenEveryEarlierOneIsMissing() async throws {
        let order: [(ProtocSource, String)] = [
            (.settingsOverride, override), (.managed, managed), (.homebrew, homebrew), (.usrLocal, usrLocal), (.path, onPath)
        ]
        for index in order.indices {
            let available = order[index...]
            var fileSystem = FakeProtocFileSystem(executables: Set(available.map(\.1)))
            if available.contains(where: { $0.0 == .managed }) {
                fileSystem.directories["/fake/Tools/protoc"] = ["36.2"]
            }
            let versions = Dictionary(uniqueKeysWithValues: available.map { ($0.1, "36.2") })
            let locator = makeLocator(fileSystem: fileSystem, versions: versions)
            let overridePath = available.first?.0 == .settingsOverride ? override : nil

            let found = try await locator.locate(overridePath: overridePath)

            XCTAssertEqual(found?.source, order[index].0, "with \(available.map(\.0))")
            XCTAssertEqual(found?.executable.path, order[index].1)
            XCTAssertEqual(found?.version, "36.2")
        }
    }

    func testABrokenOverrideThrowsRatherThanFallingBack() async {
        let fileSystem = FakeProtocFileSystem(executables: [homebrew, override])
        let locator = makeLocator(fileSystem: fileSystem, versions: [homebrew: "36.2"])

        for path in [override, "/settings/missing"] {
            do {
                _ = try await locator.locate(overridePath: path)
                XCTFail("Expected \(path) to be rejected")
            } catch let error as ProtocLocatorError {
                XCTAssertEqual(error.path, path)
            } catch {
                XCTFail("Unexpected \(error)")
            }
        }
    }

    func testCandidatesThatDoNotReportAVersionAreSkipped() async throws {
        let fileSystem = FakeProtocFileSystem(executables: [homebrew, usrLocal])
        let found = try await makeLocator(fileSystem: fileSystem, versions: [usrLocal: "3.21.12"]).locate(overridePath: nil)

        XCTAssertEqual(found?.source, .usrLocal)
        XCTAssertEqual(found?.version, "3.21.12")
    }

    func testNothingInstalledIsNil() async throws {
        let found = try await makeLocator(fileSystem: FakeProtocFileSystem(), versions: [:]).locate(overridePath: nil)

        XCTAssertNil(found)
    }

    func testTheNewestManagedVersionWinsAndStagingIsIgnored() async throws {
        let older = "/fake/Tools/protoc/9.0/bin/protoc"
        let newer = "/fake/Tools/protoc/36.2/bin/protoc"
        let staging = "/fake/Tools/protoc/.staging-1/bin/protoc"
        var fileSystem = FakeProtocFileSystem(executables: [older, newer, staging])
        fileSystem.directories["/fake/Tools/protoc"] = ["9.0", ".staging-1", "36.2"]
        let locator = makeLocator(fileSystem: fileSystem, versions: [older: "9.0", newer: "36.2", staging: "99.0"])

        let found = try await locator.locate(overridePath: nil)

        XCTAssertEqual(found?.executable.path, newer)
    }

    func testIncludeDirectoryIsBesideTheExecutableOrBesideItsResolvedTarget() async throws {
        let marker = ProtocLocator.wellKnownTypeMarker
        var managedSystem = FakeProtocFileSystem(executables: [managed], files: ["/fake/Tools/protoc/36.2/include/\(marker)"])
        managedSystem.directories["/fake/Tools/protoc"] = ["36.2"]
        let managedFound = try await makeLocator(fileSystem: managedSystem, versions: [managed: "36.2"]).locate(overridePath: nil)
        XCTAssertEqual(managedFound?.includeDirectory?.path, "/fake/Tools/protoc/36.2/include")

        let homebrewSystem = FakeProtocFileSystem(executables: [homebrew], files: ["/opt/homebrew/include/\(marker)"])
        let homebrewFound = try await makeLocator(fileSystem: homebrewSystem, versions: [homebrew: "36.2"]).locate(overridePath: nil)
        XCTAssertEqual(homebrewFound?.includeDirectory?.path, "/opt/homebrew/include")

        // A `PATH` link into an unpacked release whose own prefix has no include folder.
        let target = "/opt/protoc-36.2/bin/protoc"
        let linked = FakeProtocFileSystem(executables: [onPath], files: ["/opt/protoc-36.2/include/\(marker)"], symlinks: [onPath: target])
        let linkedFound = try await makeLocator(fileSystem: linked, versions: [onPath: "36.2"]).locate(overridePath: nil)
        XCTAssertEqual(linkedFound?.includeDirectory?.path, "/opt/protoc-36.2/include")

        let bare = FakeProtocFileSystem(executables: [usrLocal])
        let bareFound = try await makeLocator(fileSystem: bare, versions: [usrLocal: "36.2"]).locate(overridePath: nil)
        XCTAssertNotNil(bareFound)
        XCTAssertNil(bareFound?.includeDirectory)
    }

    func testVersionParsing() {
        XCTAssertEqual(ProtocLocator.parseVersion("libprotoc 36.2\n"), "36.2")
        XCTAssertEqual(ProtocLocator.parseVersion("libprotoc 3.21.12"), "3.21.12")
        XCTAssertNil(ProtocLocator.parseVersion("protoc-gen-swift 1.0"))
        XCTAssertNil(ProtocLocator.parseVersion(""))
    }

    private func makeLocator(fileSystem: FakeProtocFileSystem, versions: [String: String]) -> ProtocLocator {
        ProtocLocator(
            toolsDirectory: tools,
            fileSystem: fileSystem,
            environment: ["PATH": "/usr/bin:/bin:relative/bin:/custom/bin:/opt/homebrew/bin"],
            runner: StubCommandRunner.protocVersions(versions)
        )
    }
}
