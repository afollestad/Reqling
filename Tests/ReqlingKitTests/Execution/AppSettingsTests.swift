import Foundation
import ReqlingKit
import XCTest

final class AppSettingsTests: XCTestCase {
    func testMissingAndInvalidValuesDecodeToDefaultsAndNumbersClamp() throws {
        let json = #"{"theme": "sepia", "requestTimeoutSeconds": 9999, "verifyTLS": false}"#
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.theme, .system)
        XCTAssertEqual(decoded.requestTimeoutSeconds, AppSettings.timeoutRange.upperBound)
        XCTAssertTrue(decoded.followRedirects)
        XCTAssertFalse(decoded.verifyTLS)
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8)), AppSettings())
    }

    func testAssignmentsClampToo() {
        var settings = AppSettings()
        settings.requestTimeoutSeconds = 0

        XCTAssertEqual(settings.requestTimeoutSeconds, AppSettings.timeoutRange.lowerBound)
    }

    func testGRPCSettingsDecodeLeniently() throws {
        let json = #"{"protocPath": "  ", "grpcDeadlineSeconds": -4}"#
        var decoded = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))

        XCTAssertNil(decoded.protocPath, "a blank override means search")
        XCTAssertEqual(decoded.grpcDeadlineSeconds, AppSettings.timeoutRange.lowerBound)
        decoded.protocPath = " /opt/protoc/bin/protoc\n"
        decoded.grpcDeadlineSeconds = .infinity
        let roundTripped = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(decoded))
        XCTAssertEqual(roundTripped.protocPath, "/opt/protoc/bin/protoc")
        XCTAssertEqual(roundTripped.grpcDeadlineSeconds, 30)
        XCTAssertNil(AppSettings().protocPath)
    }

    @MainActor
    func testTheStorePersistsToItsDefaultsDomain() throws {
        let suite = "com.afollestad.reqling.tests.settings.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        SettingsStore(defaults: defaults).update { $0.theme = .dark }

        XCTAssertEqual(SettingsStore(defaults: defaults).settings.theme, .dark)
    }
}
