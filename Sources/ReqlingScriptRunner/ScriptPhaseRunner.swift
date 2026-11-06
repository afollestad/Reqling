import Foundation
import JavaScriptCore
import ReqlingScriptProtocol

/// Runs a phase's levels, outermost first, each in a fresh `JSContext` on one virtual machine, so one level's globals
/// never leak into the next while the variables, the request, and the report limits carry across. A pre-request
/// phase stops at its first failed level, since the request won't be sent; a post-response phase runs every level.
final class ScriptPhaseRunner {
    let input: ScriptRunnerInput
    let runtime: ScriptRuntimeFiles
    let events: EventWriter
    let variables: ScriptVariables
    let request: ScriptRequestModel
    let reporter: ScriptReporter
    let response: ScriptResponseAccess?

    init(input: ScriptRunnerInput, blobs: [Data], runtime: ScriptRuntimeFiles, events: EventWriter) {
        self.input = input
        self.runtime = runtime
        self.events = events
        variables = ScriptVariables(layers: input.variables, limits: input.limits, events: events)
        request = ScriptRequestModel(snapshot: input.request, phase: input.phase, limits: input.limits, events: events)
        reporter = ScriptReporter(limits: input.limits, events: events)
        response = input.response.map { ScriptResponseAccess(response: $0, blobs: blobs) }
    }

    /// False only when JavaScriptCore couldn't make a context; a script's own failure is reported as an event.
    func run() -> Bool {
        let machine = JSVirtualMachine()
        for (index, level) in input.levels.enumerated() {
            events.write(.levelStarted(level: index))
            guard let context = JSContext(virtualMachine: machine) else {
                return false
            }
            let host = ScriptLevelHost(index: index, level: level, context: context, phase: self)
            if let error = host.run() {
                events.write(.levelFailed(level: index, error: error))
                if input.phase == .preRequest {
                    return true
                }
            } else {
                events.write(.levelFinished(level: index))
            }
        }
        return true
    }
}

/// Console messages and test results, trimmed to the phase's limits across all its levels.
final class ScriptReporter {
    private let limits: ScriptLimits
    private let events: EventWriter
    private var consoleCount = 0
    private var testCount = 0

    init(limits: ScriptLimits, events: EventWriter) {
        self.limits = limits
        self.events = events
    }

    func console(level: Int, severity: ScriptConsoleSeverity, text: String) {
        consoleCount += 1
        if consoleCount == limits.consoleEntries + 1 {
            events.write(.console(level: level, severity: .warn, text: "Further console messages from this phase were not kept."))
        }
        guard consoleCount <= limits.consoleEntries else {
            return
        }
        events.write(.console(level: level, severity: severity, text: Self.trimmed(text, to: limits.consoleEntryLength)))
    }

    func test(level: Int, name: String, result: ScriptTestResult, message: String?) {
        testCount += 1
        if testCount == limits.tests + 1 {
            events.write(.console(level: level, severity: .warn, text: "Further tests in this phase were not reported."))
        }
        guard testCount <= limits.tests else {
            return
        }
        let trimmedMessage = message.map { Self.trimmed($0, to: limits.testMessageLength) }
        events.write(.test(level: level, name: Self.trimmed(name, to: limits.testNameLength), result: result, message: trimmedMessage))
    }

    static func trimmed(_ text: String, to length: Int) -> String {
        guard text.utf16.count > length else {
            return text
        }
        return String(text.prefix(length)) + "…"
    }
}

/// `rq.response`'s data: its description as JSON, and the body, decoded once and only when a script reads it.
final class ScriptResponseAccess {
    let response: ScriptResponseSnapshot
    private let blobs: [Data]
    private var text: String?

    init(response: ScriptResponseSnapshot, blobs: [Data]) {
        self.response = response
        self.blobs = blobs
    }

    /// What `runtime.js` builds `rq.response` from, keyed by `kind`; absent values are `null`.
    var object: [String: Any] {
        switch response {
        case .http(let http):
            return [
                "kind": "http", "code": http.code, "status": http.status, "headers": Self.rows(http.headers),
                "size": http.size, "truncated": http.truncated, "responseTime": http.responseTime
            ]
        case .eventStream(let stream):
            return [
                "kind": "eventStream", "code": stream.code, "status": stream.status, "headers": Self.rows(stream.headers),
                "events": stream.events.map { event -> [String: Any] in
                    ["id": Self.nullable(event.id), "event": Self.nullable(event.event), "data": event.data, "retry": Self.nullable(event.retry)]
                },
                "end": stream.end, "omittedEventCount": stream.omittedEventCount, "responseTime": stream.responseTime
            ]
        case .grpc(let call):
            return [
                "kind": "grpc",
                "status": [
                    "code": Self.nullable(call.statusCode), "name": Self.nullable(call.statusName), "message": Self.nullable(call.statusMessage)
                ],
                "metadata": Self.rows(call.metadata), "trailers": Self.rows(call.trailers), "messages": call.messages,
                "sentCount": call.sentCount, "receivedCount": call.receivedCount, "responseTime": call.responseTime
            ]
        case .webSocket(let socket):
            return [
                "kind": "webSocket", "code": Self.nullable(socket.code), "headers": Self.rows(socket.headers),
                "subprotocol": Self.nullable(socket.subprotocol),
                "messages": socket.messages.map { message -> [String: Any] in
                    ["direction": message.direction, "text": Self.nullable(message.text), "base64": Self.nullable(message.base64)]
                },
                "close": socket.closeCode.map { ["code": $0, "reason": socket.closeReason ?? ""] as [String: Any] } ?? NSNull(),
                "end": socket.end, "responseTime": socket.responseTime
            ]
        }
    }

    /// `null` in JavaScript for a missing value.
    static func nullable(_ value: Any?) -> Any {
        value ?? NSNull()
    }

    static func rows(_ rows: [ScriptRow]) -> [[String]] {
        rows.map { [$0.name, $0.value] }
    }

    var body: Data {
        guard case .http(let http) = response, blobs.indices.contains(http.body.index) else {
            return Data()
        }
        return blobs[http.body.index]
    }

    var bodyText: String {
        if let text {
            return text
        }
        // `text()` decodes as browsers do, one bad byte becoming U+FFFD, rather than losing the body.
        // swiftlint:disable:next optional_data_string_conversion
        let decoded = String(decoding: body, as: UTF8.self)
        text = decoded
        return decoded
    }
}
