import Foundation
import MCP

/// Running a folder's or project's requests in order, as the window's Run Folder… does, through the one `BatchRunner`
/// the window shares: the person sees the run in the sidebar and can stop it, and either side is refused while the
/// other's is going.
@MainActor
struct MCPBatchTools {
    let context: MCPToolContext

    /// Inside the tool's 600-second timeout, so the step in flight stops and what finished comes back rather than the
    /// dispatcher's timeout error, which would lose it all.
    static let timeLimit: Duration = .seconds(570)
    /// What the per-request totals and the steps may take, measured as the dispatcher measures them; it counts the text
    /// and the structured copy of a result against 1 MB and refuses the whole result past that.
    static let resultBudget = 350 * 1_024
    /// A step's message is cut to this many characters.
    static let messageLimit = 500

    var tools: [MCPTool] {
        [runFolder]
    }

    private var runFolder: MCPTool {
        MCPTool(
            "run_folder",
            title: "Run folder",
            description: "Runs every request in a folder, or the whole project, in sidebar order, a number of times or once per "
                + "`data` row, through each request's scripts, so values they set reach the requests after them. Each run lands "
                + "in its request's history and shows in Reqling's sidebar. Returns totals per request and the runs that didn't "
                + "pass; read one with get_run. Refused while another folder or project run is going. Event streams and "
                + "WebSockets stop after streamSeconds; the whole run stops after 9.5 minutes, returning what finished.",
            properties: [
                "project": MCPSchema.project,
                "folder": MCPSchema.string("A folder's ID, from get_project or list_requests. Omit to run the whole project."),
                "requests": MCPSchema.array(
                    MCPSchema.string("A request's ID."),
                    "Only these requests of the folder or project, still in sidebar order. Omit for all.",
                    minItems: 1
                ),
                "environment": MCPSchema.runEnvironment,
                "variables": MCPSchema.stringMap("One-run values that beat every environment's and the data's, by key."),
                "iterations": MCPSchema.integer("How many times to run the requests. Default 1; not with `data`.", minimum: 1, maximum: 10_000),
                "data": MCPSchema.array(
                    MCPSchema.openObject("One iteration's variables."),
                    "One object per iteration, each key a {{variable}} for it. Values become text: a number as JSON writes it "
                        + "(1.50 becomes 1.5), and an object or array as compact JSON. Not with `iterations`.",
                    minItems: 1
                ),
                "stopOnFailure": MCPSchema.boolean("End the run at the first request that fails. Default false."),
                "streamSeconds": MCPSchema.number(
                    "Event streams and WebSockets: stop each after this many seconds. Default 10. gRPC calls keep their deadline.",
                    minimum: 1,
                    maximum: 300
                )
            ],
            required: ["project"],
            annotations: .network,
            timeout: .seconds(600)
        ) { arguments in
            let (project, document) = try context.document(try arguments.string("project"))
            let folder = try arguments.optionalString("folder").map { try context.folder($0, in: document) }
            let requests = try Self.requests(arguments, in: folder, of: document, context: context)
            let environment = try arguments.optionalString("environment").map { try context.environment($0, in: document) }
                ?? context.workspace.activeEnvironment(in: document)
            let overrides = try arguments.stringMap("variables") ?? [:]
            let seconds = try arguments.optionalNumber("streamSeconds", in: 1...300) ?? Double(BatchRunPlan.defaultStreamSeconds)
            let plan = BatchRunPlan(
                scope: BatchRunScope(projectID: project.id, folderID: folder?.id),
                environmentID: environment.id,
                requests: requests.map(\.id),
                iterations: try Self.iterations(arguments),
                stopsOnFailure: try arguments.bool("stopOnFailure", default: false),
                streamLimit: StreamLimit(maxDuration: .milliseconds(Int(seconds * 1_000))),
                variableOverrides: overrides,
                timeLimit: Self.timeLimit
            )
            // One sink for every step, so a value one step's scripts made secret is masked wherever a later one shows it.
            let secrets = ScriptSecretSink()
            let handle: BatchRunHandle
            do throws(BatchRunRefusal) {
                handle = try await context.batches.begin(plan, mayPromptForTrust: false, scriptSecrets: secrets)
            } catch {
                throw MCPToolError(error.localizedDescription)
            }
            let run = await handle.finished()
            let mask = secrets.masking(context.runner.maskingSecrets(in: project.id, variableOverrides: overrides))
            let names = Dictionary(uniqueKeysWithValues: requests.map { ($0.id, $0.name) })
            return .object(Self.describe(run, names: names, mask: mask))
        }
    }

    /// The folder's or project's requests in sidebar order, narrowed to `requests` when given.
    private static func requests(
        _ arguments: MCPArguments,
        in folder: RequestFolder?,
        of document: ProjectDocument,
        context: MCPToolContext
    ) throws -> [RequestItem] {
        let inScope = document.requests(inFolder: folder?.id)
        let scopeName = folder.map { "folder “\($0.name)”" } ?? "“\(document.name)”"
        guard !inScope.isEmpty else {
            throw MCPToolError("\(scopeName) has no requests to run.")
        }
        guard let picked = try arguments.stringArray("requests") else {
            return inScope
        }
        let ids = try Set(picked.map { try context.request($0, in: document).id })
        let outside = ids.subtracting(inScope.map(\.id))
        guard outside.isEmpty else {
            throw MCPToolError("\(outside.map(\.description).sorted().joined(separator: ", ")) isn't in \(scopeName).")
        }
        return inScope.filter { ids.contains($0.id) }
    }

    private static func iterations(_ arguments: MCPArguments) throws -> BatchRunPlan.Iterations {
        let count = try arguments.optionalInteger("iterations", in: 1...IterationData.maximumRows)
        guard let data = try arguments.optionalArray("data") else {
            return .count(count ?? 1)
        }
        guard count == nil else {
            throw MCPToolError("Pass `iterations` or `data`, not both: each data row is one iteration.")
        }
        // Through the data-file reader, so an agent's rows convert and are capped as a file's are.
        do throws(IterationDataError) {
            let rows = try IterationData.parse(Data(MCPJSON.text(.array(data), compact: true).utf8), fileExtension: "json")
            return .data(source: .inline, rows: rows)
        } catch {
            throw MCPToolError("`data`: \(error.message)")
        }
    }

    // MARK: - Output

    /// The run's outcome: totals, then each request's, then every step that didn't pass, each list cut to fit
    /// `resultBudget` with what was left out counted.
    static func describe(_ run: BatchRun, names: [RequestNodeID: String], mask: (String) -> String) -> [String: Value] {
        var description: [String: Value] = [
            "scope": .string(mask(run.scopeName)),
            "environment": .string(run.environmentName),
            "iterations": .int(run.plan.iterationCount),
            "ended": .string(endName(run.state)),
            "totals": counts(run.counts)
        ]
        if !run.notes.isEmpty {
            description["notes"] = .array(run.notes.map { .string(mask($0)) })
        }
        var budget = Budget(bytes: resultBudget / 2)
        let requests = run.plan.requests.compactMap { id -> Value? in
            guard let tally = run.tallies[id] else {
                return nil
            }
            var entry = counts(tally.counts).objectValue ?? [:]
            entry["request"] = .string(id.description)
            entry["name"] = .string(mask(names[id] ?? ""))
            if tally.tests.total > 0 {
                entry["tests"] = MCPExecutionTools.testSummary(tally.tests)
            }
            if !tally.failedIterations.isEmpty {
                entry["failedIterations"] = .array(tally.failedIterations.prefix(20).map(Value.int))
            }
            return .object(entry)
        }
        description["requests"] = .array(budget.fitting(requests))
        if budget.omitted > 0 {
            description["requestsOmitted"] = .int(budget.omitted)
        }
        budget = Budget(bytes: resultBudget - budget.used)
        description["notPassed"] = .array(budget.fitting(run.notableSteps.map { step(described: $0, names: names, mask: mask) }))
        let omittedSteps = budget.omitted + run.omittedNotableSteps
        if omittedSteps > 0 {
            description["stepsOmitted"] = .int(omittedSteps)
        }
        return description
    }

    private static func step(described step: BatchRunStep, names: [RequestNodeID: String], mask: (String) -> String) -> Value {
        var entry = step.summary.flatMap { MCPHistoryTools.describe($0).objectValue } ?? [:]
        // The same for every step; `run`, which get_run reads, is there only for a step that was recorded.
        entry["startedAt"] = nil
        entry["environment"] = nil
        entry["iteration"] = .int(step.iteration)
        entry["request"] = .string(step.requestID.description)
        entry["name"] = .string(mask(names[step.requestID] ?? step.requestName))
        entry["result"] = .string(step.result.rawValue)
        if let message = step.message {
            let masked = mask(message)
            entry["message"] = .string(masked.count > messageLimit ? String(masked.prefix(messageLimit)) + "…" : masked)
        }
        return .object(entry)
    }

    private static func counts(_ counts: BatchStepCounts) -> Value {
        .object([
            "passed": .int(counts.passed),
            "failed": .int(counts.failed),
            "skipped": .int(counts.skipped),
            "interrupted": .int(counts.interrupted)
        ])
    }

    private static func endName(_ state: BatchRun.State) -> String {
        switch state {
        case .running: "running"
        case .ended(.finished): "finished"
        case .ended(.stoppedOnFailure): "stoppedOnFailure"
        case .ended(.stopped): "stopped"
        case .ended(.timeLimit): "timeLimit"
        case .ended(.projectRemoved): "projectRemoved"
        case .ended(.environmentRemoved): "environmentRemoved"
        }
    }

    /// Takes values in order while they fit, measuring each as the dispatcher does, and counts the rest.
    private struct Budget {
        let bytes: Int
        private(set) var used = 0
        private(set) var omitted = 0

        init(bytes: Int) {
            self.bytes = bytes
        }

        mutating func fitting(_ values: [Value]) -> [Value] {
            var kept: [Value] = []
            for value in values {
                let size = MCPJSON.text(value).utf8.count
                guard omitted == 0, used + size <= bytes else {
                    omitted += 1
                    continue
                }
                used += size
                kept.append(value)
            }
            return kept
        }
    }
}
