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
                + "or streamEvents arrive, then returned with its events. A WebSocket connects, sends its on-connect messages "
                + "(or `messages`), and returns everything that crossed it once it closes or reaches the same bounds. Its "
                + "scripts' tests and console come back too. Fails before sending when a variable is undefined, listing the "
                + "names, unless allowUnresolved is set. The run shows in Reqling's window.",
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
            let secrets = ScriptSecretSink()
            options.scriptSecrets = secrets
            let mask = context.runner.maskingSecrets(in: project.id, variableOverrides: options.variableOverrides)
            let exchange = await context.runner.run(request.id, in: project.id, options: options)
            var description = Self.describe(exchange, mask: secrets.masking(mask))
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
                "grpc": MCPRequestTools.grpcSpecSchema,
                "websocket": MCPRequestTools.webSocketSpecSchema
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
            let secrets = ScriptSecretSink()
            options.scriptSecrets = secrets
            let mask = context.runner.maskingSecrets(in: project.id, variableOverrides: options.variableOverrides)
            let exchange = await context.runner.runUnsaved(unsaved, in: project.id, options: options)
            return .object(Self.describe(exchange, mask: secrets.masking(mask)))
        }
    }

    private var resolveRequest: MCPTool {
        MCPTool(
            "resolve_request",
            title: "Preview resolved request",
            description: "What a saved request would send, {{variables}} resolved and secrets masked, without sending it. Its "
                + "pre-request scripts run, but nothing they set is kept. Lists any undefined variables.",
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
            let mask = context.runner.maskingSecrets(in: project.id, variableOverrides: options.variableOverrides)
            do {
                var description: [String: Value]
                let report: ScriptReport?
                switch request.kind {
                case .http:
                    let preview = try await context.runner.previewHTTP(request.id, in: project.id, options: options)
                    description = [
                        "request": try MCPJSON.encode(preview.prepared.summary),
                        "unresolvedVariables": .array(preview.prepared.unresolvedVariables.map(Value.string))
                    ]
                    report = preview.scriptReport
                case .grpc:
                    let preview = try await context.runner.previewGRPC(request.id, in: project.id, options: options)
                    description = [
                        "target": .string(preview.target),
                        "rpc": .string(preview.methodPath),
                        "metadata": try MCPJSON.encode(preview.metadata),
                        "messages": .array(preview.messages.map(Value.string)),
                        "unresolvedVariables": .array(preview.unresolvedVariables.map(Value.string))
                    ]
                    report = preview.scriptReport
                case .webSocket:
                    let preview = try await context.runner.previewWebSocket(request.id, in: project.id, options: options)
                    description = try Self.resolved(preview)
                    report = preview.scriptReport
                }
                if let report {
                    description.merge(Self.scripts(report, mask: mask)) { $1 }
                }
                return .object(description)
            } catch let failure as RunFailure {
                throw MCPToolError(mask(failure.message))
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
            "gRPC and WebSocket: the messages to send in order, in place of the spec's. gRPC takes proto3 JSON objects or "
                + #"strings. A WebSocket sends a string or a JSON object as text, and {"format": "binary", "text": "<base64>"} "#
                + "as binary."
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

    /// `kind` with the `messages` argument in place of its own: a gRPC call's, or a WebSocket's on-connect messages.
    private static func applyingMessages(_ arguments: MCPArguments, to kind: RequestKind) throws -> RequestKind {
        guard let messages = try arguments.optionalArray("messages") else {
            return kind
        }
        switch kind {
        case .grpc(var spec):
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
        case .webSocket(var spec):
            spec.messages = try messages.enumerated().map { index, message in try webSocketMessage(message, at: index) }
            return .webSocket(spec)
        case .http:
            throw MCPToolError("`messages` is for gRPC and WebSocket requests; change an HTTP body through `overrides`.")
        }
    }

    /// A string goes as text, and so does any JSON object but one naming its `format`, which is a message spec.
    private static func webSocketMessage(_ message: Value, at index: Int) throws -> WebSocketMessage {
        switch message {
        case .string(let text):
            return WebSocketMessage(text: text)
        case .object(let object) where object["format"] != nil:
            guard let format = object["format"]?.stringValue.flatMap(WebSocketMessageFormat.init(rawValue:)),
                  let text = object["text"]?.stringValue, object.keys.allSatisfy(["format", "text"].contains) else {
                throw MCPToolError(#"messages[\#(index)] with a `format` must be {"format": "text" | "binary", "text": "…"}."#)
            }
            return WebSocketMessage(format: format, text: text)
        case .object:
            return WebSocketMessage(text: MCPJSON.text(message, compact: true))
        default:
            throw MCPToolError("messages[\(index)] must be a string or a JSON object.")
        }
    }

    private static func adHocKind(_ arguments: MCPArguments) throws -> RequestKind {
        guard let kind = try MCPRequestTools.specArgument(arguments) else {
            throw MCPToolError("Pass one of `http`, `grpc`, or `websocket`.")
        }
        return kind
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
        case .webSocket(let record):
            description["connection"] = .object(webSocket(record, cachedCut: exchange.isBodyTruncated, mask: mask))
        case .failure(let failure):
            description["failure"] = ["kind": .string(failure.kind.rawValue), "message": .string(mask(failure.message))]
        }
        if let report = exchange.scriptReport {
            description.merge(scripts(report, mask: mask)) { $1 }
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
