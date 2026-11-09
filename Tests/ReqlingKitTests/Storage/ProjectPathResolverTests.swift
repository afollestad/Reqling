import Foundation
@testable import ReqlingKit
import XCTest

/// Shared paths come from whoever wrote the project, so they resolve only inside its folder or repository.
final class ProjectPathResolverTests: XCTestCase {
    private var root: URL!
    /// The slot most tests read from; a shared path inside the project resolves in any.
    private let body = ProjectPathSlot.binaryBody(RequestNodeID())

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

        XCTAssertEqual(resolver.url(for: .relative("body.json"), in: body)?.lastPathComponent, "body.json")
        XCTAssertEqual(resolver.url(for: .relative("data/missing.json"), in: body)?.lastPathComponent, "missing.json")
        XCTAssertEqual(resolver.describe(.relative("body.json"), in: body), "“body.json”")
    }

    func testAPathThatClimbsOutIsTreatedAsMissing() throws {
        let project = try folder("API.reqling")
        try Data("secret".utf8).write(to: root.appendingPathComponent("id_rsa"))
        let resolver = ProjectPathResolver(projectRoot: project, localPaths: [:], homeDirectory: root)

        XCTAssertNil(resolver.url(for: .relative("../id_rsa"), in: body))
        XCTAssertNil(resolver.url(for: .relative("data/../../id_rsa"), in: body))
        XCTAssertEqual(resolver.describe(.relative("../id_rsa"), in: body), "“../id_rsa” (outside the project’s folder and repository)")
        XCTAssertThrowsError(try resolver.data(for: .relative("../id_rsa"), in: body))
    }

    func testASymlinkInsideTheProjectThatLeadsOutIsTreatedAsMissing() throws {
        let project = try folder("API.reqling")
        let secret = root.appendingPathComponent("id_rsa")
        try Data("secret".utf8).write(to: secret)
        try FileManager.default.createSymbolicLink(at: project.appendingPathComponent("body.bin"), withDestinationURL: secret)
        let resolver = ProjectPathResolver(projectRoot: project, localPaths: [:], homeDirectory: root)

        XCTAssertNil(resolver.url(for: .relative("body.bin"), in: body))
    }

    func testARepositoryWidensTheSharedLocationToItsRoot() throws {
        let repository = try folder("Home/src/api")
        try folder("Home/src/api/.git")
        let project = try folder("Home/src/api/Requests.reqling")
        let schema = repository.appendingPathComponent("schema.graphql")
        try Data("type Query { a: Int }".utf8).write(to: schema)
        let resolver = ProjectPathResolver(projectRoot: project, localPaths: [:], homeDirectory: root.appendingPathComponent("Home"))

        XCTAssertEqual(resolver.url(for: .relative("../schema.graphql"), in: body)?.lastPathComponent, "schema.graphql")
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

        XCTAssertNil(resolver.url(for: .relative("../../.ssh-key"), in: body))
        XCTAssertFalse(ProjectPathResolver.sharesLocation(secret, with: project, homeDirectory: home))
    }

    /// A shared path outside resolves only where the person chose it (Shared Path); the same path written by anyone
    /// else, or moved into another field, stays missing.
    func testAnOutsidePathResolvesOnlyWhereThePersonChoseIt() throws {
        let project = try folder("API.reqling")
        try folder("Schemas")
        try Data("type Query { a: Int }".utf8).write(to: root.appendingPathComponent("Schemas/api.graphql"))
        let schema = ProjectPathSlot.graphQLSchema(RequestNodeID())
        let chosen = ProjectPathResolver(
            projectRoot: project,
            localPaths: [:],
            choices: [.relative("../Schemas/api.graphql"): [schema]],
            homeDirectory: root
        )

        XCTAssertEqual(chosen.url(for: .relative("../Schemas/api.graphql"), in: schema)?.lastPathComponent, "api.graphql")
        XCTAssertEqual(chosen.describe(.relative("../Schemas/api.graphql"), in: schema), "“../Schemas/api.graphql”")
        XCTAssertNil(chosen.url(for: .relative("../Schemas/../Schemas/api.graphql"), in: schema), "Only the exact path chosen")
        XCTAssertNil(chosen.url(for: .relative("../Schemas/api.graphql"), in: body), "Only in the field it was chosen for")
        let elsewhere = chosen.describe(.relative("../Schemas/api.graphql"), in: body)
        XCTAssertEqual(elsewhere, "“../Schemas/api.graphql” (chosen on this Mac for another field)")
    }

    /// A file used for a client certificate or key reads only as one, by whatever reference reaches it, so a request
    /// can't send it.
    func testAClientCertificatesFileIsReadOnlyForTLS() throws {
        let project = try folder("API.reqling")
        try folder("API.reqling/certs")
        let key = project.appendingPathComponent("certs/client.p12")
        try Data("identity".utf8).write(to: key)
        let id = LocalPathID()
        let certificate = ProjectPathSlot.clientCertificate(CertificateEntryID())
        // Chosen for the request too, as an older copy of the project may have it: being marked still wins.
        let choices: [ProjectPathReference: Set<ProjectPathSlot>] = [.local(id): [certificate, body]]
        let unmarked = ProjectPathResolver(projectRoot: project, localPaths: [id: key.path], choices: choices, homeDirectory: root)
        let marked = ProjectPathResolver(
            projectRoot: project,
            localPaths: [id: key.path],
            choices: choices,
            identityFiles: unmarked.resolvedPaths(of: [PlacedPathReference(.relative("certs/client.p12"), in: certificate)]),
            homeDirectory: root
        )

        for reference in [ProjectPathReference.local(id), .relative("certs/client.p12"), .relative("certs/../certs/client.p12")] {
            XCTAssertNotNil(unmarked.url(for: reference, in: body))
            XCTAssertNil(marked.url(for: reference, in: body), "\(reference)")
            XCTAssertThrowsError(try marked.data(for: reference, in: body))
            XCTAssertEqual(try marked.identityData(for: reference, in: certificate), Data("identity".utf8))
        }
    }

    /// A this-Mac path may point anywhere, but only from the field it was chosen for: another Mac or a repository can
    /// move its reference, never choose it again.
    func testAThisMacPathResolvesOnlyInTheFieldItWasChosenFor() throws {
        let project = try folder("API.reqling")
        let id = LocalPathID()
        let request = RequestNodeID()
        let field = MultipartFieldID()
        let resolver = ProjectPathResolver(
            projectRoot: project,
            localPaths: [id: "/Users/me/upload.bin"],
            choices: [.local(id): [.formField(request, field)]],
            homeDirectory: root
        )

        XCTAssertEqual(resolver.url(for: .local(id), in: .formField(request, field))?.path, "/Users/me/upload.bin")
        XCTAssertEqual(resolver.describe(.local(id), in: .formField(request, field)), "“upload.bin”")
        for elsewhere in [ProjectPathSlot.binaryBody(request), .formField(request, MultipartFieldID()), .formField(RequestNodeID(), field)] {
            XCTAssertNil(resolver.url(for: .local(id), in: elsewhere), "\(elsewhere)")
            XCTAssertNil(resolver.identityFileURL(for: .local(id), in: elsewhere), "\(elsewhere)")
            XCTAssertEqual(resolver.describe(.local(id), in: elsewhere), "A file chosen for another field")
        }
        XCTAssertEqual(resolver.describe(.local(LocalPathID()), in: body), "A file chosen on another Mac")
    }

    /// Slots are written into `workspace.json` by key, and read back as the same slot.
    func testSlotsRoundTripThroughTheirKeys() {
        let request = RequestNodeID()
        let slots: [ProjectPathSlot] = [
            .binaryBody(request), .formField(request, MultipartFieldID()), .graphQLSchema(request), .descriptorSet(request),
            .clientCertificate(CertificateEntryID()), .caCertificates, .protoRoots, .projectDescriptorSets
        ]

        XCTAssertEqual(slots.map { ProjectPathSlot(key: $0.key) }, slots)
        XCTAssertEqual(Set(slots.map(\.key)).count, slots.count)
        XCTAssertNil(ProjectPathSlot(key: "binaryBody/not-an-id"))
        XCTAssertNil(ProjectPathSlot(key: "headerFile/\(request)"))
    }

    @discardableResult
    private func folder(_ path: String) throws -> URL {
        let url = root.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
