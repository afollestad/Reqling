import Foundation
import ReqlingTemplating

/// One step of a folder or project run, which `RequestRunner.run` takes through `RunOptions.batchStep`: what the step
/// starts from (its iteration, data row, and the run-local values earlier steps left) and what it leaves for the next.
/// Only `BatchRunner` makes one.
@MainActor
final class BatchStepContext {
    let iteration: Int
    let iterationCount: Int
    let iterationData: [String: String]
    /// `rq.variables` values the iteration's earlier steps left; the step's scripts start from them, and hand back theirs.
    var locals: [String: TemplateVariable]
    /// Every value an earlier step of the iteration made secret for the run alone, which masking keeps covering even
    /// after a script unsets it.
    var carriedSecrets: Set<String>
    /// Set by `record` once the step's run reached the history; a run another run of its request replaced never does.
    var wasRecorded = false
    /// Set by `RequestRunner.cancel`: the person's Stop, an agent's `cancel_request`, or the run's own stop.
    var wasCancelled = false
    /// What the step's scripts named to run next (`rq.execution.setNextRequest`).
    var nextRequest: ScriptNextRequest?

    init(iteration: Int, iterationCount: Int, iterationData: [String: String], locals: [String: TemplateVariable], carriedSecrets: Set<String>) {
        self.iteration = iteration
        self.iterationCount = iterationCount
        self.iterationData = iterationData
        self.locals = locals
        self.carriedSecrets = carriedSecrets
    }
}

/// Where a folder or project run's steps meet `run`: registering the step, so `cancel` can mark it, and handing back
/// what its scripts left. A step without scripts keeps the values it was handed, for the steps after it.
extension RequestRunner {
    func beginBatchStep(_ step: BatchStepContext?, key: RunKey, run: RunID, options: RunOptions) {
        batchSteps[key] = step
        // Before any exchange exists, so an open stream an agent reads is masked even when its request has no scripts.
        if let step, options.unsaved == nil {
            scriptSecrets.remember(step.carriedSecrets, for: run)
        }
    }

    /// Unregisters `step`, unless a newer run of the request has registered its own since.
    func endBatchStep(_ step: BatchStepContext?, key: RunKey) {
        if let step, batchSteps[key] === step {
            batchSteps[key] = nil
        }
    }

    func finishBatchStep(_ step: BatchStepContext?, session: ScriptSession?) {
        guard let step, let session else {
            return
        }
        step.locals = session.layers.local
        step.carriedSecrets.formUnion(session.layers.local.values.filter(\.isSecret).map(\.value))
        step.nextRequest = session.nextRequest
    }
}
