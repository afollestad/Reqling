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
}
