import Foundation
import ReqlingScriptProtocol

/// Runs one phase of one request's scripts and exits. Reqling writes the input to standard input and closes it, reads
/// events as they come (`EventWriter`), and kills this process at the phase's time limit; nothing here bounds time.
/// Exit statuses are `ScriptRunnerExit`'s.
@main
enum ScriptRunnerMain {
    static func main() {
        // A Reqling that stopped reading must not kill this process mid-write; the write just fails.
        signal(SIGPIPE, SIG_IGN)
        let events = EventWriter.takingStandardOutput()
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard let frames = ScriptFraming.frames(in: data),
              let header = frames.first,
              let input = try? JSONDecoder().decode(ScriptRunnerInput.self, from: header),
              input.protocolVersion == ScriptRunnerInput.currentProtocolVersion else {
            exit(ScriptRunnerExit.badInput)
        }
        guard let runtime = ScriptRuntimeFiles(directory: URL(fileURLWithPath: input.runtimeDirectory, isDirectory: true)) else {
            exit(ScriptRunnerExit.missingRuntime)
        }
        let phase = ScriptPhaseRunner(input: input, blobs: Array(frames.dropFirst()), runtime: runtime, events: events)
        guard phase.run() else {
            exit(ScriptRunnerExit.noContext)
        }
        events.write(.done)
        exit(ScriptRunnerExit.success)
    }
}
