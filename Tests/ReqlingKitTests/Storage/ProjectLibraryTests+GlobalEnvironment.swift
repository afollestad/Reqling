import Foundation
import ReqlingKit
import XCTest

/// The Global environment every project shares, kept beside the registry rather than in any project.
@MainActor
extension ProjectLibraryTests {
    func testGlobalSavesOnThisMacWithItsSecretsInTheKeychain() throws {
        XCTAssertEqual(fixture.library.globalEnvironment, .global())
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.globalEnvironmentURL.path))

        try fixture.library.mutateGlobalEnvironment { global in
            global.name = "Renamed"
            global.variables = [Variable(key: "base", value: "https://api"), Variable(key: "token", value: "s3cr3t", isSecret: true)]
        }

        let file = try String(contentsOf: fixture.globalEnvironmentURL, encoding: .utf8)
        XCTAssertTrue(file.contains("https://api"))
        XCTAssertFalse(file.contains("s3cr3t"))
        XCTAssertEqual(try fixture.secrets.secrets(for: .global).values.sorted(), ["s3cr3t"])
        let relaunched = fixture.relaunched()
        XCTAssertEqual(relaunched.globalEnvironment.name, "Global")
        XCTAssertEqual(relaunched.globalEnvironment.variables.map(\.value), ["https://api", "s3cr3t"])
        XCTAssertNil(relaunched.globalEnvironmentIssue)
    }

    func testRemovingAGlobalSecretDeletesItsValue() throws {
        try fixture.library.mutateGlobalEnvironment { $0.variables = [Variable(key: "token", value: "s3cr3t", isSecret: true)] }

        try fixture.library.mutateGlobalEnvironment { $0.variables.removeAll() }

        XCTAssertTrue(try fixture.secrets.secrets(for: .global).isEmpty)
    }

    func testAFailedGlobalWriteLeavesMemoryAsItWas() throws {
        try fixture.library.mutateGlobalEnvironment { $0.variables = [Variable(key: "base", value: "https://api")] }
        let saved = fixture.library.globalEnvironment
        // A directory where the file goes makes the atomic write's final rename fail.
        try FileManager.default.removeItem(at: fixture.globalEnvironmentURL)
        try FileManager.default.createDirectory(at: fixture.globalEnvironmentURL, withIntermediateDirectories: false)

        XCTAssertThrowsError(try fixture.library.mutateGlobalEnvironment { $0.variables[0].value = "https://other" })
        XCTAssertEqual(fixture.library.globalEnvironment, saved)
    }

    func testAnUndecodableGlobalFileIsSetAsideAndReported() throws {
        try FileManager.default.createDirectory(at: fixture.globalEnvironmentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "<<<<<<< HEAD".write(to: fixture.globalEnvironmentURL, atomically: true, encoding: .utf8)

        let relaunched = fixture.relaunched()

        XCTAssertEqual(relaunched.globalEnvironment, .global())
        XCTAssertNotNil(relaunched.globalEnvironmentIssue)
        let names = try FileManager.default.contentsOfDirectory(atPath: fixture.globalEnvironmentURL.deletingLastPathComponent().path)
        XCTAssertTrue(names.contains { $0.hasPrefix("global-environment.corrupt-") })
        XCTAssertFalse(names.contains("global-environment.json"))
    }

    func testUnreadableGlobalSecretsAreReportedAndLeftBlank() throws {
        try fixture.library.mutateGlobalEnvironment { $0.variables = [Variable(key: "token", value: "s3cr3t", isSecret: true)] }

        let relaunched = fixture.relaunched(secretStore: LockableSecretStore(wrapping: fixture.secrets))

        XCTAssertEqual(relaunched.globalEnvironment.variables.map(\.value), [""])
        XCTAssertEqual(relaunched.globalEnvironmentIssue, "Secret values could not be read from the Keychain.")
    }

    func testGlobalSecretsLoadOnceTheKeychainOpensWithoutARelaunch() throws {
        try fixture.library.mutateGlobalEnvironment { $0.variables = [Variable(key: "token", value: "s3cr3t", isSecret: true)] }
        let keychain = LockableSecretStore(wrapping: fixture.secrets)
        let relaunched = fixture.relaunched(secretStore: keychain)

        relaunched.reloadGlobalSecretsIfUnread()
        XCTAssertEqual(relaunched.globalEnvironment.variables.map(\.value), [""])
        XCTAssertNotNil(relaunched.globalEnvironmentIssue)

        keychain.isLocked = false
        try relaunched.mutateGlobalEnvironment { $0.variables.append(Variable(key: "base", value: "https://api")) }

        XCTAssertEqual(relaunched.globalEnvironment.variables.map(\.value), ["s3cr3t", "https://api"])
        XCTAssertNil(relaunched.globalEnvironmentIssue)
        XCTAssertEqual(try fixture.secrets.secrets(for: .global).values.sorted(), ["s3cr3t"])
    }
}
