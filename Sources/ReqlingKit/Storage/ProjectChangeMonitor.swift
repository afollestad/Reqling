import CoreServices
import Foundation

/// Watches a project folder for changes made outside Reqling, such as a `git pull` or an editor.
public protocol ProjectChangeMonitor: AnyObject {
    func stop()
}

/// Creates a monitor that calls `onChange` on the main actor; returns `nil` when watching is unavailable.
public typealias ProjectChangeMonitorFactory = @MainActor (URL, @escaping @MainActor () -> Void) -> (any ProjectChangeMonitor)?

/// An FSEvents stream over the project folder. Events are coalesced over `latency`, and the library reloads and
/// compares content, so Reqling's own writes cost a read but never a visible change.
public final class FSEventsProjectMonitor: ProjectChangeMonitor {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.afollestad.reqling.project-monitor")

    public static let factory: ProjectChangeMonitorFactory = { url, onChange in
        FSEventsProjectMonitor(url: url, latency: 0.3, onChange: onChange)
    }

    public init?(url: URL, latency: TimeInterval, onChange: @escaping @MainActor () -> Void) {
        let handler = Handler(onChange: onChange)
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
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else {
                return
            }
            Unmanaged<Handler>.fromOpaque(info).takeUnretainedValue().fire()
        }
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [url.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        ) else {
            return nil
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    deinit {
        stop()
    }

    public func stop() {
        guard let stream else {
            return
        }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private final class Handler: Sendable {
        let onChange: @MainActor () -> Void

        init(onChange: @escaping @MainActor () -> Void) {
            self.onChange = onChange
        }

        func fire() {
            Task { @MainActor [onChange] in
                onChange()
            }
        }
    }
}
