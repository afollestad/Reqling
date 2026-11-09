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

    /// Settings saved before updates existed check automatically; a value of the wrong type falls back the same way.
    func testUpdateChecksDefaultOnAndDecodeLeniently() throws {
        let missing = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        let invalid = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"checksForUpdatesAutomatically": "nope"}"#.utf8))
        let off = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"checksForUpdatesAutomatically": false}"#.utf8))

        XCTAssertTrue(missing.checksForUpdatesAutomatically)
        XCTAssertTrue(invalid.checksForUpdatesAutomatically)
        XCTAssertFalse(off.checksForUpdatesAutomatically)
    }

    /// Settings saved before history existed keep 30 days within 500 MB; an unknown choice falls back the same way.
    /// Settings saved before iCloud sync existed sync, as a new install does; turned off, it stays off.
    func testICloudSyncDefaultsOnAndRoundTrips() throws {
        let missing = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        var off = AppSettings()
        off.syncsWithICloud = false

        XCTAssertTrue(missing.syncsWithICloud)
        XCTAssertFalse(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(off)).syncsWithICloud)
    }

    func testHistorySettingsDefaultAndDecodeLeniently() throws {
        let missing = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        let invalid = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"historyRetention": "fortnight", "historySizeLimit": 3}"#.utf8))
        let chosen = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"historyRetention": "week", "historySizeLimit": "1GB"}"#.utf8))

        XCTAssertEqual(missing.historyRetention, .month)
        XCTAssertEqual(missing.historySizeLimit, .megabytes500)
        XCTAssertEqual(invalid.historyRetention, .month)
        XCTAssertEqual(invalid.historySizeLimit, .megabytes500)
        XCTAssertEqual(chosen.historyRetention, .week)
        XCTAssertEqual(chosen.historySizeLimit, .gigabytes1)
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

    func testTheScriptTimeLimitDefaultsAndClamps() throws {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"scriptTimeLimitSeconds": 9000}"#.utf8))
        var settings = AppSettings()
        settings.scriptTimeLimitSeconds = 0

        XCTAssertEqual(AppSettings().scriptTimeLimitSeconds, 10)
        XCTAssertEqual(decoded.scriptTimeLimitSeconds, AppSettings.scriptTimeLimitRange.upperBound)
        XCTAssertEqual(settings.scriptTimeLimitSeconds, AppSettings.scriptTimeLimitRange.lowerBound)
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
