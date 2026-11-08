import Foundation
import ReqlingScriptProtocol

/// Runs one phase of one request's scripts and exits. Reqling writes the input to standard input, reads events as they
/// come (`EventWriter`), and kills this process at the time limit; nothing here bounds time. Exit statuses are
/// `ScriptRunnerExit`'s.
///
/// Most phases get their input whole, then standard input closes. A stream phase's input stays open while its stream
/// does: each item for its handlers follows as a frame (`ScriptStreamInput`), read on a thread of its own, and the
/// phase ends once the input closes and the item in hand is done.
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
        let ran: Bool
        if let stream = input.stream {
            let inbox = ScriptStreamInbox(canSend: stream.canSend)
            Thread.detachNewThread {
                inbox.read(from: reader)
            }
            ran = ScriptPhaseRunner(input: input, blobs: [], runtime: runtime, events: events, inbox: inbox).runStream()
        } else {
            ran = ScriptPhaseRunner(input: input, blobs: blobs(from: reader), runtime: runtime, events: events).run()
        }
        guard ran else {
            exit(ScriptRunnerExit.noContext)
        }
        events.write(.done)
        exit(ScriptRunnerExit.success)
    }

    /// The bodies after the header, to the input's end.
    private static func blobs(from reader: ScriptInputReader) -> [Data] {
        var blobs: [Data] = []
        while true {
            switch reader.next() {
            case .frame(let blob):
                blobs.append(blob)
            case .end:
                return blobs
            case .corrupt:
                exit(ScriptRunnerExit.badInput)
            }
        }
    }
}
