import Foundation
import JavaScriptCore
import ReqlingScriptProtocol

/// Runs a phase's levels, outermost first, each in a fresh `JSContext` on one virtual machine, so one level's globals
/// never leak into the next while the variables, the request, the cookies, and the report limits carry across. A
/// pre-request phase stops at its first failed level, since the request won't be sent; the other phases run every
/// level.
///
/// A stream phase (`runStream`) keeps every level's context once its top level has run, since the handlers it
/// registered live there, and hands each item from the inbox to them in level order: one call per item.
final class ScriptPhaseRunner {
    let input: ScriptRunnerInput
    let runtime: ScriptRuntimeFiles
    let events: EventWriter
    let variables: ScriptVariables
    let request: ScriptRequestModel
    let cookies: ScriptCookies
    let reporter: ScriptReporter
    let response: ScriptResponseAccess?
    /// A stream phase's items; `nil` in every other phase.
    let inbox: ScriptStreamInbox?
    /// What `rq.execution` asked last, across every level, so a script calling it in a loop writes one event per
    /// change rather than one per call, which no limit would bound.
    private var skipsRequest = false
    private var nextRequest: String?? = .none
    /// What `rq.send` sent in the top level or the call in hand.
    private var sends = 0

    init(input: ScriptRunnerInput, blobs: [Data], runtime: ScriptRuntimeFiles, events: EventWriter, inbox: ScriptStreamInbox? = nil) {
        self.input = input
        self.runtime = runtime
        self.events = events
        self.inbox = inbox
        variables = ScriptVariables(layers: input.variables, limits: input.limits, events: events)
        request = ScriptRequestModel(snapshot: input.request, phase: input.phase, limits: input.limits, events: events)
        cookies = ScriptCookies(snapshot: input.cookies, request: request, variables: variables, limits: input.limits, events: events)
        reporter = ScriptReporter(limits: input.limits, events: events)
        if let response = input.response {
            self.response = ScriptResponseAccess(response: response, blobs: blobs)
        } else {
            self.response = input.stream.map { ScriptResponseAccess(opening: $0.opening) }
        }
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

    /// Runs every level's top level, then hands each item to the handlers until the input ends. A level whose top
    /// level threw gets no calls: its handlers may depend on what it never set up. A handler that throws keeps getting
    /// later items, as an `EventSource` listener does. False only when JavaScriptCore couldn't make a context.
    func runStream() -> Bool {
        guard let inbox else {
            return false
        }
        let machine = JSVirtualMachine()
        var hosts: [ScriptLevelHost] = []
        for (index, level) in input.levels.enumerated() {
            events.write(.levelStarted(level: index))
            guard let context = JSContext(virtualMachine: machine) else {
                return false
            }
            let host = ScriptLevelHost(index: index, level: level, context: context, phase: self)
            if let error = host.run() {
                events.write(.levelFailed(level: index, error: error))
            } else {
                events.write(.levelFinished(level: index))
                hosts.append(host)
            }
        }
        let handlers = hosts.reduce(0) { $0 + $1.handlerCount }
        events.write(.registered(handlers: handlers))
        guard handlers > 0 else {
            return true
        }
        while let item = inbox.next() {
            beginCall()
            events.write(.callStarted(item: item.number))
            for host in hosts where host.handles(item) {
                if let error = host.handle(item) {
                    events.write(.levelFailed(level: host.index, error: error))
                }
            }
            events.write(.callFinished(item: item.number))
        }
        return true
    }

    /// Gives the next handler call limits of its own, since a stream can run for as long as it stays open.
    private func beginCall() {
        reporter.beginCall()
        variables.beginCall()
        cookies.beginCall()
        sends = 0
    }

    /// Reports a stream script's `rq.send`; the runtime has already turned the script's value into `message`.
    func send(_ message: ScriptOutgoingMessage, level: Int) throws(ScriptFailure) {
        guard input.phase == .stream, let inbox else {
            throw ScriptFailure("rq.send works only in stream scripts.")
        }
        guard inbox.canSend else {
            throw ScriptFailure(input.info.protocolName == "grpc"
                ? "rq.send can't send: the call's request stream is closed."
                : "rq.send can't send: the connection is closed.")
        }
        guard sends < input.limits.sends else {
            throw ScriptFailure("Scripts can send at most \(input.limits.sends) messages in one \(reporter.unit).")
        }
        guard message.byteCount <= input.limits.sendLength else {
            throw ScriptFailure("rq.send can send at most \(input.limits.sendLength / 1_024 / 1_024) MB in one message.")
        }
        sends += 1
        events.write(.send(level: level, message: message))
    }

    func skipRequest() {
        guard !skipsRequest else {
            return
        }
        skipsRequest = true
        events.write(.flow(.skipRequest))
    }

    /// `nil` ends the iteration.
    func setNextRequest(_ request: String?) {
        guard nextRequest != .some(request) else {
            return
        }
        nextRequest = .some(request)
        events.write(.flow(.setNextRequest(request)))
    }
}

/// Console messages and test results, trimmed to the phase's limits across all its levels, or in a stream phase, to
/// the top level's and then each call's.
final class ScriptReporter {
    private let limits: ScriptLimits
    private let events: EventWriter
    private var consoleCount = 0
    private var testCount = 0
    /// What a limit applies to, as its messages name it.
    private(set) var unit = "phase"

    init(limits: ScriptLimits, events: EventWriter) {
        self.limits = limits
        self.events = events
    }

    func beginCall() {
        consoleCount = 0
        testCount = 0
        unit = "handler call"
    }

    func console(level: Int, severity: ScriptConsoleSeverity, text: String) {
        consoleCount += 1
        if consoleCount == limits.consoleEntries + 1 {
            events.write(.console(level: level, severity: .warn, text: "Further console messages from this \(unit) were not kept."))
        }
        guard consoleCount <= limits.consoleEntries else {
            return
        }
        events.write(.console(level: level, severity: severity, text: Self.trimmed(text, to: limits.consoleEntryLength)))
    }

    func test(level: Int, name: String, result: ScriptTestResult, message: String?) {
        testCount += 1
        if testCount == limits.tests + 1 {
            events.write(.console(level: level, severity: .warn, text: "Further tests in this \(unit) were not reported."))
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

/// `rq.response`'s data: its description as JSON, and the body, decoded once and only when a script reads it. A stream
/// phase's is what the stream opened with, and has no body.
final class ScriptResponseAccess {
    private enum Source {
        case response(ScriptResponseSnapshot)
        case opening(ScriptStreamOpening)
    }

    private let source: Source
    private let blobs: [Data]
    private var text: String?

    init(response: ScriptResponseSnapshot, blobs: [Data]) {
        source = .response(response)
        self.blobs = blobs
    }

    init(opening: ScriptStreamOpening) {
        source = .opening(opening)
        blobs = []
    }

    /// What `runtime.js` builds `rq.response` from, keyed by `kind`; absent values are `null`.
    var object: [String: Any] {
        switch source {
        case .response(let response):
            Self.object(response)
        case .opening(.eventStream(let code, let status, let headers)):
            ["kind": "eventStream", "code": code, "status": status, "headers": Self.rows(headers)]
        case .opening(.webSocket(let code, let headers, let subprotocol)):
            ["kind": "webSocket", "code": Self.nullable(code), "headers": Self.rows(headers), "subprotocol": Self.nullable(subprotocol)]
        case .opening(.grpc(let metadata)):
            ["kind": "grpc", "metadata": Self.rows(metadata)]
        }
    }

    private static func object(_ response: ScriptResponseSnapshot) -> [String: Any] {
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
        guard case .response(.http(let http)) = source, blobs.indices.contains(http.body.index) else {
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
