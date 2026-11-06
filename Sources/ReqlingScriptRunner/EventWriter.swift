import Foundation
import ReqlingScriptProtocol

/// Writes events to Reqling, framed (`ScriptFraming`), each as soon as it happens.
///
/// It writes to a private copy of the standard output it started with, and points standard output itself at
/// `/dev/null`, so nothing else that prints (a framework, a stray debug line) can corrupt the event stream.
final class EventWriter {
    private let descriptor: Int32
    private let encoder = JSONEncoder()

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    static func takingStandardOutput() -> EventWriter {
        let events = dup(STDOUT_FILENO)
        let null = open("/dev/null", O_WRONLY)
        if null >= 0 {
            dup2(null, STDOUT_FILENO)
            close(null)
        }
        return EventWriter(descriptor: events)
    }

    func write(_ event: ScriptRunnerEvent) {
        guard let payload = try? encoder.encode(event) else {
            return
        }
        let frame = ScriptFraming.frame(payload)
        frame.withUnsafeBytes { buffer in
            guard var address = buffer.baseAddress else {
                return
            }
            var remaining = buffer.count
            while remaining > 0 {
                let written = Foundation.write(descriptor, address, remaining)
                if written < 0, errno == EINTR {
                    continue
                }
                // Reqling stopped reading: the run is over, and so is reporting.
                guard written > 0 else {
                    return
                }
                address += written
                remaining -= written
            }
        }
    }
}
