import CoreServices
@testable import ReqlingKit
import XCTest

final class FSEventsProtoChangesTests: XCTestCase {
    func testOnlySchemaChangesAreRelevant() {
        let sets: Set<String> = ["/repo/schema/api.binpb"]
        let file = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemModified)
        let folderRenamed = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemRenamed)
        let folderCreated = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemCreated)
        let rescan = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)

        XCTAssertTrue(FSEventsProtoChanges.isRelevant(path: "/repo/protos/a.proto", flags: file, descriptorSets: sets))
        XCTAssertTrue(FSEventsProtoChanges.isRelevant(path: "/repo/schema/api.binpb", flags: file, descriptorSets: sets))
        XCTAssertTrue(FSEventsProtoChanges.isRelevant(path: "/repo/protos/v2", flags: folderRenamed, descriptorSets: sets))
        XCTAssertTrue(FSEventsProtoChanges.isRelevant(path: "/repo", flags: rescan, descriptorSets: sets))
        XCTAssertFalse(FSEventsProtoChanges.isRelevant(path: "/repo/schema/other.binpb", flags: file, descriptorSets: sets))
        XCTAssertFalse(FSEventsProtoChanges.isRelevant(path: "/repo/.build/x.o", flags: file, descriptorSets: sets))
        XCTAssertFalse(FSEventsProtoChanges.isRelevant(path: "/repo/protos/new", flags: folderCreated, descriptorSets: sets))
    }

    func testWritingAProtoUnderAWatchedRootReportsAChange() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let root = directory.file("protos")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("v1"), withIntermediateDirectories: true)

        try await waitForChange(watching: [root]) {
            try Data("syntax = \"proto3\";\n".utf8).write(to: root.appendingPathComponent("v1/api.proto"))
        }
    }

    /// The temporary directory sits under `/var`, a symlink to `/private/var`, so the event path matches the watched
    /// descriptor set only when the watcher resolves it the way FSEvents reports it.
    func testRewritingAWatchedDescriptorSetReportsAChange() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let descriptorSet = directory.file("schema/api.binpb")
        try FileManager.default.createDirectory(at: descriptorSet.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0]).write(to: descriptorSet)

        try await waitForChange(watching: [descriptorSet]) {
            try Data([1]).write(to: descriptorSet)
        }
    }

    /// Runs `change` only after the stream is watching, since it reports events from `kFSEventStreamEventIdSinceNow`,
    /// then fails unless the stream yields within a bounded wait. A stream that ends without yielding fails too, so a
    /// watcher that gives up on setup cannot pass.
    private func waitForChange(watching urls: [URL], after change: () throws -> Void) async throws {
        let changes = FSEventsProtoChanges.stream(watching: urls)
        let watcher = Task { () -> Bool in
            for await _ in changes {
                return true
            }
            return false
        }
        // Ends the iteration, and with it the FSEvents stream, when `change` throws.
        defer { watcher.cancel() }
        try change()
        // `bounded` fails the test itself on a timeout, returning `nil`.
        if await bounded("A change under \(urls.map(\.lastPathComponent))", timeout: 10, watcher) == false {
            XCTFail("The stream ended without reporting a change under \(urls.map(\.lastPathComponent))")
        }
    }
}
