import Foundation
import ReqlingScriptProtocol

/// Runs one phase of one request's scripts and exits. Reqling writes the input to standard input, reads events as they
/// come (`EventWriter`), and kills this process at the time limit; nothing here bounds time. Exit statuses are
/// `ScriptRunnerExit`'s.
///
/// The input's header and bodies come first. Standard input then stays open: `ScriptRunnerMessage` frames follow,
/// read on a thread of its own into a `ScriptInbox`, for a stream phase's items and for the replies to the requests
/// scripts send. A stream phase ends once its items have ended and the item in hand is done.
@main
enum ScriptRunnerMain {
    static func main() {
        // A Reqling that stopped reading must not kill this process mid-write; the write just fails.
        signal(SIGPIPE, SIG_IGN)
        let events = EventWriter.takingStandardOutput()
        let reader = ScriptInputReader()
        guard case .frame(let header) = reader.next(),
              let input = try? JSONDecoder().decode(ScriptRunnerInput.self, from: header),
              input.protocolVersion == ScriptRunnerInput.currentProtocolVersion,
              (input.phase == .stream) == (input.stream != nil) else {
            exit(ScriptRunnerExit.badInput)
        }
        guard let runtime = ScriptRuntimeFiles(directory: URL(fileURLWithPath: input.runtimeDirectory, isDirectory: true)) else {
            exit(ScriptRunnerExit.missingRuntime)
        }
        let blobs = blobs(input.blobCount, from: reader)
        let inbox = ScriptInbox(canSend: input.stream?.canSend ?? false)
        Thread.detachNewThread {
            inbox.read(from: reader)
        }
        let phase = ScriptPhaseRunner(input: input, blobs: blobs, runtime: runtime, events: events, inbox: inbox)
        guard input.stream == nil ? phase.run() : phase.runStream() else {
            exit(ScriptRunnerExit.noContext)
        }
        events.write(.done)
        exit(ScriptRunnerExit.success)
    }

    /// The `count` bodies after the header.
    private static func blobs(_ count: Int, from reader: ScriptInputReader) -> [Data] {
        (0..<max(count, 0)).map { _ in
            guard case .frame(let blob) = reader.next() else {
                exit(ScriptRunnerExit.badInput)
            }
            return blob
        }
    }
}
