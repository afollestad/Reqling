import Foundation
import MCP

/// Sending requests and reading their results. A saved request's run shows in the window like one sent from there; an
/// ad hoc run does not. Secrets are masked everywhere in the output, including where a server echoes one back.
@MainActor
struct MCPExecutionTools {
    let context: MCPToolContext

    /// Bodies and message JSON are cut to this many bytes in tool output, well under the dispatcher's output limit.
    static let bodyLimit = 256 * 1_024

    var tools: [MCPTool] {
        [executeRequest, executeAdHocRequest, resolveRequest, getLastResponse, cancelRequest]
    }

    private var executeRequest: MCPTool {
        MCPTool(
            "execute_request",
            title: "Send request",
            description: "Sends a saved request and waits for the response (HTTP) or the call's end (gRPC), resolving its "
                + "{{variables}} against an environment. An event-stream response is read until it ends, streamSeconds pass, "
                + "or streamEvents arrive, then returned with its events. Fails before sending when a variable is undefined, "
                + "listing the names, unless allowUnresolved is set. The run shows in Reqling's window.",
            properties: Self.runProperties.merging([
                "request": MCPSchema.request,
                "overrides": MCPSchema.openObject("One-run changes to the spec, as a merge patch like update_request's `spec`. "
                    + "The saved request is untouched.")
            ]) { $1 },
            required: ["project", "request"],
            annotations: .network,
            timeout: .seconds(600)
        ) { arguments in
            let (project, document) = try context.document(try arguments.string("project"))
            let request = try context.request(try arguments.string("request"), in: document)
            var kind = request.kind
            if let patch = try arguments.optionalObject("overrides") {
                kind = try MCPRequestTools.patched(kind, with: .object(patch))
            }
            var options = try runOptions(arguments, in: document)
            options.spec = try Self.applyingMessages(arguments, to: kind)
            options.streamLimit = try Self.streamLimit(arguments, for: kind)
            let mask = context.runner.maskingSecrets(in: project.id, variableOverrides: options.variableOverrides)
            let exchange = await context.runner.run(request.id, in: project.id, options: options)
            var description = Self.describe(exchange, mask: mask)
            // Only a recorded run can be read back with get_run; a run replaced by a newer one, or of a project removed
            // meanwhile, never was.
            if context.runner.latest[RunKey(request.id, in: project.id)]?.id == exchange.id {
                description["run"] = .string(exchange.id.description)
            }
            return .object(description)
        }
    }

    private var executeAdHocRequest: MCPTool {
        MCPTool(
            "execute_ad_hoc_request",
            title: "Send unsaved request",
            description: "Sends a request that isn't saved, resolving its {{variables}} against a project's environments and auth "
                + "as if it were saved at the project's top level. Nothing is saved or shown in the window.",
            properties: Self.runProperties.merging([
                "name": MCPSchema.string("A name for messages about the run."),
                "http": MCPRequestTools.httpSpecSchema,
                "grpc": MCPRequestTools.grpcSpecSchema
            ]) { $1 },
            required: ["project"],
            annotations: .network,
            timeout: .seconds(600)
        ) { arguments in
            let (project, document) = try context.document(try arguments.string("project"))
            let item = RequestItem(name: try arguments.optionalString("name") ?? "Unsaved request", kind: try Self.adHocKind(arguments))
            var options = try runOptions(arguments, in: document)
            options.streamLimit = try Self.streamLimit(arguments, for: item.kind)
            var unsaved = item
            unsaved.kind = try Self.applyingMessages(arguments, to: item.kind)
            let mask = context.runner.maskingSecrets(in: project.id, variableOverrides: options.variableOverrides)
            let exchange = await context.runner.runUnsaved(unsaved, in: project.id, options: options)
            return .object(Self.describe(exchange, mask: mask))
        }
    }

    private var resolveRequest: MCPTool {
        MCPTool(
            "resolve_request",
            title: "Preview resolved request",
            description: "What a saved request would send, {{variables}} resolved and secrets masked, without sending it. Lists "
                + "any undefined variables.",
            properties: [
                "project": MCPSchema.project,
                "request": MCPSchema.request,
                "environment": MCPSchema.runEnvironment,
                "variables": MCPSchema.stringMap("One-off values that beat every environment's, by key.")
            ],
            required: ["project", "request"],
            annotations: .read
        ) { arguments in
            let (project, document) = try context.document(try arguments.string("project"))
            let request = try context.request(try arguments.string("request"), in: document)
            var options = try runOptions(arguments, in: document)
            options.allowUnresolved = true
            do {
                switch request.kind {
                case .http:
                    let prepared = try context.runner.prepare(request.id, in: project.id, options: options)
                    return .object([
                        "request": try MCPJSON.encode(prepared.summary),
                        "unresolvedVariables": .array(prepared.unresolvedVariables.map(Value.string))
                    ])
                case .grpc:
                    let preview = try context.runner.previewGRPC(request.id, in: project.id, options: options)
                    return .object([
                        "target": .string(preview.target),
                        "rpc": .string(preview.methodPath),
                        "metadata": try MCPJSON.encode(preview.metadata),
                        "messages": .array(preview.messages.map(Value.string)),
                        "unresolvedVariables": .array(preview.unresolvedVariables.map(Value.string))
                    ])
                }
            } catch let failure as RunFailure {
                throw MCPToolError(failure.message)
            }
        }
    }

    private var getLastResponse: MCPTool {
        MCPTool(
            "get_last_response",
            title: "Get last response",
            description: "The latest run of a saved request on this Mac, from Reqling's window or an agent, as execute_request "
                + "returns it.",
            properties: ["project": MCPSchema.project, "request": MCPSchema.request],
            required: ["project", "request"],
            annotations: .read
        ) { arguments in
            let (project, document) = try context.document(try arguments.string("project"))
            let request = try context.request(try arguments.string("request"), in: document)
            guard let exchange = context.runner.exchange(for: request.id, in: project.id) else {
                return .object(["ran": false])
            }
            var description = Self.describe(exchange, mask: context.runner.maskingSecrets(in: project.id))
            description["ran"] = true
            description["run"] = .string(exchange.id.description)
            description["inFlight"] = .bool(context.runner.isInFlight(request.id, in: project.id))
            return .object(description)
        }
    }

    private var cancelRequest: MCPTool {
        MCPTool(
            "cancel_request",
            title: "Cancel request",
            description: "Stops a saved request's run in flight, whether it started in the window or from execute_request. A "
                + "stopped event stream keeps the events so far.",
            properties: ["project": MCPSchema.project, "request": MCPSchema.request],
            required: ["project", "request"],
            annotations: .edit
        ) { arguments in
            let (project, document) = try context.document(try arguments.string("project"))
            let request = try context.request(try arguments.string("request"), in: document)
            let wasInFlight = context.runner.isInFlight(request.id, in: project.id)
            context.runner.cancel(request.id, in: project.id)
            return .object(["cancelled": .bool(wasInFlight)])
        }
    }

    // MARK: - Arguments

    static let runProperties: [String: Value] = [
        "project": MCPSchema.project,
        "environment": MCPSchema.runEnvironment,
        "variables": MCPSchema.stringMap("One-run values that beat every environment's, by key."),
        "messages": MCPSchema.array(
            ["type": ["object", "string"]],
            "gRPC only: the messages to send in order, as proto3 JSON objects or strings, in place of the spec's."
        ),
        "allowUnresolved": MCPSchema.boolean("Send even with undefined {{variables}}, which go out as written.")
    ].merging(streamProperties) { $1 }

    private func runOptions(_ arguments: MCPArguments, in document: ProjectDocument) throws -> RunOptions {
        var options = RunOptions(
            variableOverrides: try arguments.stringMap("variables") ?? [:],
            allowUnresolved: try arguments.bool("allowUnresolved", default: false)
        )
        options.environmentID = try arguments.optionalString("environment").map { try context.environment($0, in: document).id }
        return options
    }

    /// `kind` with the `messages` argument in place of its own, for gRPC.
    private static func applyingMessages(_ arguments: MCPArguments, to kind: RequestKind) throws -> RequestKind {
        guard let messages = try arguments.optionalArray("messages") else {
            return kind
        }
        guard case .grpc(var spec) = kind else {
            throw MCPToolError("`messages` is for gRPC requests; change an HTTP body through `overrides`.")
        }
        spec.messages = try messages.enumerated().map { index, message in
            switch message {
            case .string(let text):
                return text
            case .object:
                return MCPJSON.text(message)
            default:
                throw MCPToolError("messages[\(index)] must be a JSON object or a string of one.")
            }
        }
        return .grpc(spec)
    }

    private static func adHocKind(_ arguments: MCPArguments) throws -> RequestKind {
        switch (try arguments.optionalObject("http"), try arguments.optionalObject("grpc")) {
        case (let http?, nil):
            return .http(try MCPJSON.decode(HTTPRequestSpec.self, from: .object(http), path: "http").normalized())
        case (nil, let grpc?):
            return .grpc(try MCPJSON.decode(GRPCRequestSpec.self, from: .object(grpc), path: "grpc"))
        default:
            throw MCPToolError("Pass exactly one of `http` or `grpc`.")
        }
    }

    // MARK: - Output

    static func describe(_ exchange: RequestExchange, mask: (String) -> String) -> [String: Value] {
        var description: [String: Value] = [
            "environment": exchange.environmentName.map(Value.string) ?? .null,
            "startedAt": .string(ISO8601DateFormatter().string(from: exchange.startedAt)),
            "unresolvedVariables": .array(exchange.unresolvedVariables.map(Value.string))
        ]
        if let request = exchange.request, let encoded = try? MCPJSON.encode(request) {
            description["request"] = encoded
        }
        switch exchange.outcome {
        case .response(let response):
            description["response"] = .object(http(response, cachedCut: exchange.isBodyTruncated, mask: mask))
        case .grpc(let call):
            description["call"] = .object(grpc(call, cachedCut: exchange.isBodyTruncated, mask: mask))
        case .failure(let failure):
            description["failure"] = ["kind": .string(failure.kind.rawValue), "message": .string(mask(failure.message))]
        }
        return description
    }

    private static func http(_ response: HTTPResponseRecord, cachedCut: Bool, mask: (String) -> String) -> [String: Value] {
        var description: [String: Value] = [
            "status": .int(response.statusCode),
            "url": .string(mask(response.url)),
            "headers": rows(response.headers, mask: mask),
            "durationMs": .int(Int((response.duration * 1_000).rounded())),
            "byteCount": .int(response.body.count)
        ]
        if let protocolName = response.protocolName {
            description["protocol"] = .string(protocolName)
        }
        if let tlsVersion = response.tlsVersion {
            description["tlsVersion"] = .string(tlsVersion)
        }
        if let stream = response.eventStream {
            return description.merging(eventStream(stream, cachedCut: cachedCut, mask: mask)) { $1 }
        }
        if let text = String(data: response.body, encoding: .utf8) {
            let cut = prefix(text, utf8Limit: bodyLimit)
            description["body"] = .string(mask(cut))
            description["truncated"] = .bool(cachedCut || cut.utf8.count < text.utf8.count)
        } else {
            let cut = response.body.prefix(bodyLimit * 3 / 4)
            description["bodyBase64"] = .string(cut.base64EncodedString())
            description["truncated"] = .bool(cachedCut || cut.count < response.body.count)
        }
        return description
    }

    private static func grpc(_ call: GRPCCallRecord, cachedCut: Bool, mask: (String) -> String) -> [String: Value] {
        var kept: [Value] = []
        var budget = bodyLimit
        for event in call.events.reversed() {
            let json = mask(event.json)
            budget -= json.utf8.count
            guard budget >= 0 else {
                break
            }
            var message: [String: Value] = [
                "direction": .string(event.direction.rawValue),
                "offsetMs": .int(Int((event.offset * 1_000).rounded())),
                "json": .string(json),
                "byteCount": .int(event.byteCount)
            ]
            if event.unknownFieldCount > 0 {
                message["unknownFieldCount"] = .int(event.unknownFieldCount)
            }
            kept.append(.object(message))
        }
        var description: [String: Value] = [
            "target": .string(mask(call.target)),
            "rpc": .string(call.method),
            "kind": .string(call.kind.rawValue),
            "sentMetadata": rows(call.sentMetadata, mask: mask),
            "initialMetadata": rows(call.initialMetadata, mask: mask),
            "trailers": rows(call.trailers, mask: mask),
            "sentCount": .int(call.sentCount),
            "receivedCount": .int(call.receivedCount),
            "messages": .array(kept.reversed()),
            "durationMs": .int(Int((call.duration * 1_000).rounded()))
        ]
        let omitted = call.omittedEventCount + call.events.count - kept.count
        if omitted > 0 || cachedCut {
            description["omittedMessageCount"] = .int(omitted)
            description["note"] = "Only the newest messages are included."
        }
        if let status = call.status {
            description["status"] = ["code": .int(status.code), "name": .string(status.name), "message": .string(mask(status.message))]
        } else {
            description["status"] = .null
        }
        return description
    }

    private static func rows(_ rows: [KeyValuePair], mask: (String) -> String) -> Value {
        .array(rows.map { ["key": .string($0.key), "value": .string(mask($0.value))] })
    }

    /// The longest prefix of `text` within `utf8Limit` bytes, cut on a character boundary.
    private static func prefix(_ text: String, utf8Limit: Int) -> String {
        guard text.utf8.count > utf8Limit else {
            return text
        }
        var end = text.utf8.index(text.utf8.startIndex, offsetBy: utf8Limit)
        while end > text.startIndex, String.Index(end, within: text) == nil {
            end = text.utf8.index(before: end)
        }
        return String(text[..<end])
    }
}
