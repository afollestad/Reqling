import Foundation
@testable import ReqlingKit
import XCTest

/// Shared paths come from whoever wrote the project, so they resolve only inside its folder or repository.
final class ProjectPathResolverTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        // The temporary directory sits under `/var`, a symlink to `/private/var`, which the containment check must see
        // through for files that exist and files that don't alike.
        root = FileManager.default.temporaryDirectory.appendingPathComponent("rq-paths-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    func testAPathInsideTheProjectResolvesWhetherOrNotItsFileExists() throws {
        let project = try folder("API.reqling")
        try Data("{}".utf8).write(to: project.appendingPathComponent("body.json"))
        let resolver = ProjectPathResolver(projectRoot: project, localPaths: [:], homeDirectory: root)

        XCTAssertEqual(resolver.url(for: .relative("body.json"))?.lastPathComponent, "body.json")
        XCTAssertEqual(resolver.url(for: .relative("data/missing.json"))?.lastPathComponent, "missing.json")
        XCTAssertEqual(resolver.describe(.relative("body.json")), "“body.json”")
    }

    func testAPathThatClimbsOutIsTreatedAsMissing() throws {
        let project = try folder("API.reqling")
        try Data("secret".utf8).write(to: root.appendingPathComponent("id_rsa"))
        let resolver = ProjectPathResolver(projectRoot: project, localPaths: [:], homeDirectory: root)

        XCTAssertNil(resolver.url(for: .relative("../id_rsa")))
        XCTAssertNil(resolver.url(for: .relative("data/../../id_rsa")))
        XCTAssertEqual(resolver.describe(.relative("../id_rsa")), "“../id_rsa” (outside the project’s folder and repository)")
        XCTAssertThrowsError(try resolver.data(for: .relative("../id_rsa")))
    }

    func testASymlinkInsideTheProjectThatLeadsOutIsTreatedAsMissing() throws {
        let project = try folder("API.reqling")
        let secret = root.appendingPathComponent("id_rsa")
        try Data("secret".utf8).write(to: secret)
        try FileManager.default.createSymbolicLink(at: project.appendingPathComponent("body.bin"), withDestinationURL: secret)
        let resolver = ProjectPathResolver(projectRoot: project, localPaths: [:], homeDirectory: root)

        XCTAssertNil(resolver.url(for: .relative("body.bin")))
    }

    func testARepositoryWidensTheSharedLocationToItsRoot() throws {
        let repository = try folder("Home/src/api")
        try folder("Home/src/api/.git")
        let project = try folder("Home/src/api/Requests.reqling")
        let schema = repository.appendingPathComponent("schema.graphql")
        try Data("type Query { a: Int }".utf8).write(to: schema)
        let resolver = ProjectPathResolver(projectRoot: project, localPaths: [:], homeDirectory: root.appendingPathComponent("Home"))

        XCTAssertEqual(resolver.url(for: .relative("../schema.graphql"))?.lastPathComponent, "schema.graphql")
        XCTAssertTrue(ProjectPathResolver.sharesLocation(schema, with: project, homeDirectory: root.appendingPathComponent("Home")))
    }

    /// A dotfiles repository in the home folder would otherwise make the whole home folder count as the project's.
    func testARepositoryAtTheHomeFolderDoesntWidenIt() throws {
        let home = try folder("Home")
        try folder("Home/.git")
        let project = try folder("Home/Documents/API.reqling")
        let secret = home.appendingPathComponent(".ssh-key")
        try Data("secret".utf8).write(to: secret)
        let resolver = ProjectPathResolver(projectRoot: project, localPaths: [:], homeDirectory: home)

        XCTAssertNil(resolver.url(for: .relative("../../.ssh-key")))
        XCTAssertFalse(ProjectPathResolver.sharesLocation(secret, with: project, homeDirectory: home))
    }

    /// A shared path outside resolves only where the person chose it (Shared Path); the same path written by anyone
    /// else stays missing.
    func testAnOutsidePathResolvesOnlyWhereThePersonChoseIt() throws {
        let project = try folder("API.reqling")
        try folder("Schemas")
        try Data("type Query { a: Int }".utf8).write(to: root.appendingPathComponent("Schemas/api.graphql"))
        let chosen = ProjectPathResolver(
            projectRoot: project,
            localPaths: [:],
            chosenOutsidePaths: ["../Schemas/api.graphql"],
            homeDirectory: root
        )

        XCTAssertEqual(chosen.url(for: .relative("../Schemas/api.graphql"))?.lastPathComponent, "api.graphql")
        XCTAssertEqual(chosen.describe(.relative("../Schemas/api.graphql")), "“../Schemas/api.graphql”")
        XCTAssertNil(chosen.url(for: .relative("../Schemas/../Schemas/api.graphql")), "Only the exact path chosen")
    }

    /// A file used for a client certificate or key reads only as one, by whatever reference reaches it, so a request
    /// can't send it.
    func testAClientCertificatesFileIsReadOnlyForTLS() throws {
        let project = try folder("API.reqling")
        try folder("API.reqling/certs")
        let key = project.appendingPathComponent("certs/client.p12")
        try Data("identity".utf8).write(to: key)
        let id = LocalPathID()
        let unmarked = ProjectPathResolver(projectRoot: project, localPaths: [id: key.path], homeDirectory: root)
        let marked = ProjectPathResolver(
            projectRoot: project,
            localPaths: [id: key.path],
            identityFiles: unmarked.resolvedPaths(of: [.relative("certs/client.p12")]),
            homeDirectory: root
        )

        for reference in [ProjectPathReference.local(id), .relative("certs/client.p12"), .relative("certs/../certs/client.p12")] {
            XCTAssertNotNil(unmarked.url(for: reference))
            XCTAssertNil(marked.url(for: reference), "\(reference)")
            XCTAssertThrowsError(try marked.data(for: reference))
            XCTAssertEqual(try marked.identityData(for: reference), Data("identity".utf8))
        }
    }

    func testAThisMacPathMayPointAnywhere() throws {
        let project = try folder("API.reqling")
        let id = LocalPathID()
        let resolver = ProjectPathResolver(projectRoot: project, localPaths: [id: "/Users/me/client.p12"], homeDirectory: root)

        XCTAssertEqual(resolver.url(for: .local(id))?.path, "/Users/me/client.p12")
    }

    @discardableResult
    private func folder(_ path: String) throws -> URL {
        let url = root.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
