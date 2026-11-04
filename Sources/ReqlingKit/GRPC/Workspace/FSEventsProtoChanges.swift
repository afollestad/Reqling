import CoreServices
import Foundation

/// File events for proto roots and descriptor set files, from FSEvents.
///
/// Only events that can change a schema pass: `.proto` files, the descriptor set files themselves, and folder-level
/// events (a rename, or FSEvents asking for a rescan). A root is often a whole repository, and a recompile, even a
/// cache hit, rehashes every `.proto` under it, so build output and editor swap files must not trigger one.
public enum FSEventsProtoChanges {
    /// Watches `urls`: directories as roots, files as descriptor sets, through their parent folders since FSEvents
    /// watches only directories. Ends watching when the consumer stops iterating.
    public static func stream(watching urls: [URL], latency: TimeInterval = 0.3) -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        var directories: [String] = []
        var files = Set<String>()
        for url in urls {
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            if exists, isDirectory.boolValue {
                directories.append(canonicalPath(url))
            } else {
                files.insert(canonicalPath(url))
                directories.append(canonicalPath(url.deletingLastPathComponent()))
            }
        }
        let descriptorSets = files
        let source = ProtoEventSource(directories: Array(Set(directories)).sorted(), latency: latency) { events in
            if events.contains(where: { isRelevant(path: $0.path, flags: $0.flags, descriptorSets: descriptorSets) }) {
                continuation.yield()
            }
        }
        continuation.onTermination = { _ in
            source?.stop()
        }
        return stream
    }

    /// The real path, as FSEvents reports events: a symlinked root (`protos -> api/proto`) must be watched where it
    /// points. Not `URL.resolvingSymlinksInPath`, which strips the `/private` that FSEvents keeps.
    private static func canonicalPath(_ url: URL) -> String {
        guard let resolved = realpath(url.path, nil) else {
            return url.path
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func isRelevant(path: String, flags: FSEventStreamEventFlags, descriptorSets: Set<String>) -> Bool {
        if path.hasSuffix(".proto") || descriptorSets.contains(path) {
            return true
        }
        let rescan = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged)
        let folderMoved = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir)
        let moved = FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemRemoved)
        return flags & rescan != 0 || (flags & folderMoved != 0 && flags & moved != 0)
    }
}

/// One FSEvents stream reporting each batch's paths and flags. `@unchecked Sendable` because `stream` is written
/// only in `init` and `stop`, and `stop` runs on `queue`, the queue FSEvents calls back on.
private final class ProtoEventSource: @unchecked Sendable {
    typealias Event = (path: String, flags: FSEventStreamEventFlags)

    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.afollestad.reqling.proto-changes")

    init?(directories: [String], latency: TimeInterval, onEvents: @escaping @Sendable ([Event]) -> Void) {
        let handler = Handler(onEvents: onEvents)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passRetained(handler).toOpaque(),
            retain: nil,
            release: { info in
                if let info {
                    Unmanaged<Handler>.fromOpaque(info).release()
                }
            },
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info, let paths = unsafeBitCast(paths, to: NSArray.self) as? [String] else {
                return
            }
            let events = (0..<min(count, paths.count)).map { (path: paths[$0], flags: flags[$0]) }
            Unmanaged<Handler>.fromOpaque(info).takeUnretainedValue().onEvents(events)
        }
        let flags = kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            directories as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            FSEventStreamCreateFlags(flags)
        ) else {
            return nil
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    deinit {
        if let stream {
            Self.tearDown(stream)
        }
    }

    func stop() {
        queue.async { [self] in
            guard let stream else {
                return
            }
            self.stream = nil
            Self.tearDown(stream)
        }
    }

    private static func tearDown(_ stream: FSEventStreamRef) {
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    private final class Handler: Sendable {
        let onEvents: @Sendable ([Event]) -> Void

        init(onEvents: @escaping @Sendable ([Event]) -> Void) {
            self.onEvents = onEvents
        }
    }
}
