import CryptoKit
import Foundation
@testable import ReqlingKit
import Synchronization
import XCTest

final class ProtocInstallerTests: XCTestCase {
    private var directory: TemporaryDirectory!
    private var archiveURL: URL!
    /// Larger than the downloader's chunk, so progress reports more than once. `ditto` is stubbed, so the bytes only
    /// need a known digest.
    private let archive = Data((0..<150_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })

    override func setUpWithError() throws {
        directory = try TemporaryDirectory()
        archiveURL = try XCTUnwrap(URL(string: "https://fixtures.reqling.test/\(UUID().uuidString)/protoc-99.1-osx-universal_binary.zip"))
        FixtureURLProtocol.serve(archive, at: archiveURL)
    }

    override func tearDown() {
        FixtureURLProtocol.remove(archiveURL)
        directory.remove()
    }

    private var tools: URL {
        directory.file("Tools")
    }

    private var protocRoot: URL {
        tools.appendingPathComponent("protoc", isDirectory: true)
    }

    func testAVerifiedArchiveIsInstalledAndReplacesStaleVersions() async throws {
        let stale = protocRoot.appendingPathComponent("98.0/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: protocRoot.appendingPathComponent(".staging-crashed"), withIntermediateDirectories: true)
        let runner = Self.extractingRunner(archive: archive, reportedVersion: "99.1")
        let phases = Mutex<[ProtocInstallPhase]>([])

        let installed = try await makeInstaller(sha256: Self.digest(archive), runner: runner).install { phase in
            phases.withLock { $0.append(phase) }
        }

        XCTAssertEqual(installed.executable, protocRoot.appendingPathComponent("99.1/bin/protoc"))
        XCTAssertEqual(installed.source, .managed)
        XCTAssertEqual(installed.version, "99.1")
        XCTAssertEqual(installed.includeDirectory, protocRoot.appendingPathComponent("99.1/include", isDirectory: true))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: protocRoot.path), ["99.1"])

        let recorded = phases.withLock { $0 }
        XCTAssertEqual(recorded.first, .downloading(receivedBytes: 0, expectedBytes: Int64(archive.count)))
        XCTAssertEqual(Array(recorded.suffix(3)), [
            .downloading(receivedBytes: Int64(archive.count), expectedBytes: Int64(archive.count)), .verifying, .extracting
        ])
        XCTAssertGreaterThan(recorded.count, 4)

        let invocations = runner.invocations
        XCTAssertEqual(invocations.map(\.executable.lastPathComponent), ["ditto", "protoc"])
        XCTAssertEqual(Array(invocations[0].arguments.prefix(2)), ["-x", "-k"])
        XCTAssertEqual(invocations[1].arguments, ["--version"])

        // The installer's layout is the one the locator searches.
        let located = try await ProtocLocator(
            toolsDirectory: tools,
            environment: [:],
            runner: StubCommandRunner.protocVersions([installed.executable.path: "99.1"])
        ).locate(overridePath: nil)
        XCTAssertEqual(located, installed)
    }

    func testADigestMismatchThrowsBeforeExtractingAndLeavesNothingBehind() async throws {
        let runner = Self.extractingRunner(archive: archive, reportedVersion: "99.1")

        do {
            _ = try await makeInstaller(sha256: String(repeating: "0", count: 64), runner: runner).install()
            XCTFail("Expected a digest mismatch")
        } catch ProtocInstallError.digestMismatch(_, let actual) {
            XCTAssertEqual(actual, Self.digest(archive))
        }

        XCTAssertTrue(runner.invocations.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: protocRoot.path), [])
    }

    func testAWrongVersionIsNotInstalled() async throws {
        let runner = Self.extractingRunner(archive: archive, reportedVersion: "3.0")

        do {
            _ = try await makeInstaller(sha256: Self.digest(archive), runner: runner).install()
            XCTFail("Expected a version mismatch")
        } catch let error as ProtocInstallError {
            XCTAssertEqual(error, .versionMismatch(expected: "99.1", actual: "3.0"))
        }

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: protocRoot.path), [])
    }

    private func makeInstaller(sha256: String, runner: StubCommandRunner) -> ProtocInstaller {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureURLProtocol.self]
        return ProtocInstaller(
            toolsDirectory: tools,
            release: ProtocRelease(version: "99.1", archiveURL: archiveURL, sha256: sha256),
            downloader: ProtocDownloader(configuration: configuration),
            runner: runner
        )
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Stands in for `ditto -x -k` by writing the release layout, and for the unpacked protoc's `--version`.
    private static func extractingRunner(archive: Data, reportedVersion: String) -> StubCommandRunner {
        StubCommandRunner { invocation in
            if invocation.executable.lastPathComponent == "ditto" {
                let arguments = invocation.arguments
                XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: arguments[2])), archive)
                let destination = URL(fileURLWithPath: arguments[3], isDirectory: true)
                let bin = destination.appendingPathComponent("bin", isDirectory: true)
                let include = destination.appendingPathComponent("include/google/protobuf", isDirectory: true)
                try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: include, withIntermediateDirectories: true)
                try Data("#!/bin/sh\n".utf8).write(to: bin.appendingPathComponent("protoc"))
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appendingPathComponent("protoc").path)
                try Data().write(to: include.appendingPathComponent("descriptor.proto"))
                return CommandResult(exitCode: 0)
            }
            return CommandResult(exitCode: 0, standardOutput: Data("libprotoc \(reportedVersion)\n".utf8))
        }
    }
}

/// Serves registered bodies by URL. Each test registers a URL with a unique path, so parallel tests never share an
/// entry.
final class FixtureURLProtocol: URLProtocol {
    private static let bodies = Mutex<[URL: Data]>([:])

    static func serve(_ body: Data, at url: URL) {
        bodies.withLock { $0[url] = body }
    }

    static func remove(_ url: URL?) {
        guard let url else {
            return
        }
        _ = bodies.withLock { $0.removeValue(forKey: url) }
    }

    override static func canInit(with request: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url, let body = Self.bodies.withLock({ $0[url] }),
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "\(body.count)"])
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .allowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
