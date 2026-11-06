import Foundation
import ReqlingKit

/// A project waiting for the person at the Mac to decide whether its scripts may run; see `AppModel.decideScriptTrust`.
struct ScriptTrustRequest: Identifiable, Equatable {
    let id = UUID()
    let projectName: String
    let files: [String]

    var title: String {
        "Run the scripts in “\(projectName)”?"
    }

    /// What a script can reach, which is why a project from elsewhere asks first.
    var message: String {
        let shown = files.prefix(6).joined(separator: "\n")
        let more = files.count > 6 ? "\n…and \(files.count - 6) more" : ""
        return "Its scripts can read this project's variables and Global's, secrets included, and add them to its requests. "
            + "Reqling remembers your answer on this Mac.\n\n\(shown)\(more)"
    }
}

/// The trust question as an alert: one at a time, answered by `answerScriptTrust`. A new question while one is open
/// answers the open one "not now", which runs without scripts and asks again next time.
extension AppModel: ScriptTrustDeciding {
    func decideScriptTrust(projectName: String, files: [String]) async -> Bool? {
        await withCheckedContinuation { continuation in
            trustContinuation?.resume(returning: nil)
            trustContinuation = continuation
            scriptTrustPending = ScriptTrustRequest(projectName: projectName, files: files)
        }
    }

    /// `nil` dismisses the question without deciding.
    func answerScriptTrust(_ answer: Bool?) {
        scriptTrustPending = nil
        let continuation = trustContinuation
        trustContinuation = nil
        continuation?.resume(returning: answer)
    }

    func scriptTrust(for project: ProjectID) -> ScriptTrust {
        workspace.projectState(project).scriptTrust
    }

    func setScriptTrust(_ trust: ScriptTrust, for project: ProjectID) {
        workspace.updateProject(project) { $0.scriptTrust = trust }
    }
}
