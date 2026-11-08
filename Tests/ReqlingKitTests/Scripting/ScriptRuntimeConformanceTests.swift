import CryptoKit
import Foundation
@testable import ReqlingKit
import ReqlingScriptProtocol
import ReqlingTemplating
import XCTest

/// `ScriptAPICatalog` against the runtime the helper runs, both ways, in every phase and for every protocol: each
/// member the catalog says applies exists with its declared type, and each key the runtime exposes on `rq`, `pm`, and
/// what they hold is in the catalog. One helper launch per context checks every path at once, and passes every
/// callback (`ScriptValueType.callback`) a method takes there, checking what each is called with: a stream's handlers,
/// and `pm.sendRequest`'s, whose request the fixture answers.
@MainActor
final class ScriptRuntimeConformanceTests: XCTestCase {
    private let fixtures = ScriptFixtures()
    private let catalog = ScriptAPICatalog.standard

    private struct Context {
        let name: String
        let phase: ScriptPhase
        let requestProtocol: String
        let response: ScriptResponseSnapshot?
        let protocols: ScriptProtocols
        /// What a stream context's handlers are called with.
        var item: ScriptStreamItem?
    }

    /// One path to read, and the `typeof` it must give.
    private struct Probe: Encodable {
        let path: [String]
        let expected: [String]
        /// Through an optional value or an array element the fixture may not have.
        let mayBeMissing: Bool
    }

    /// One object whose own keys must all be documented on `type`.
    private struct Walked: Encodable {
        let path: [String]
        let type: String
    }

    /// A method that takes a callback, which the probe passes to check what it's called with; its probes and walks
    /// are paths into the callback's parameter at `position`.
    private struct Handler: Encodable {
        let method: [String]
        /// Where the callback goes among the method's arguments; those before it get a URL.
        let argument: Int
        let position: Int
        var probes: [Probe] = []
        var walked: [Walked] = []
    }

    private var contexts: [Context] {
        let body = #"{"id": 7}"#
        return [
            Context(name: "pre http", phase: .preRequest, requestProtocol: "http", response: nil, protocols: .http),
            Context(name: "pre grpc", phase: .preRequest, requestProtocol: "grpc", response: nil, protocols: [.grpc]),
            Context(name: "pre websocket", phase: .preRequest, requestProtocol: "websocket", response: nil, protocols: [.webSocket]),
            Context(name: "post http", phase: .postResponse, requestProtocol: "http", response: .http(ScriptHTTPResponse(
                code: 200, status: "OK", headers: [ScriptRow(name: "A", value: "1")], body: ScriptBlob(index: 0, size: body.utf8.count),
                size: body.utf8.count, truncated: false, responseTime: 1
            )), protocols: [.http]),
            Context(name: "post event stream", phase: .postResponse, requestProtocol: "http", response: .eventStream(ScriptEventStreamResponse(
                code: 200, status: "OK", headers: [], events: [ScriptStreamEvent(id: "1", event: "e", data: "{}", retry: 5)],
                end: "closed", omittedEventCount: 0, responseTime: 1
            )), protocols: [.eventStream]),
            Context(name: "post grpc", phase: .postResponse, requestProtocol: "grpc", response: .grpc(ScriptGRPCResponse(
                statusCode: 0, statusName: "ok", statusMessage: "", metadata: [], trailers: [], messages: ["{}"],
                sentCount: 1, receivedCount: 1, responseTime: 1
            )), protocols: [.grpc]),
            Context(name: "post websocket", phase: .postResponse, requestProtocol: "websocket", response: .webSocket(ScriptWebSocketResponse(
                code: 101, headers: [], subprotocol: "chat", messages: [ScriptSocketMessage(direction: "received", text: "{}", base64: nil)],
                closeCode: 1000, closeReason: "bye", end: "closed", responseTime: 1
            )), protocols: [.webSocket]),
            Context(name: "stream event stream", phase: .stream, requestProtocol: "http", response: nil, protocols: [.eventStream],
                    item: ScriptStreamItem(number: 1, content: .event(ScriptStreamEvent(id: "1", event: "e", data: "{}", retry: 5)))),
            Context(name: "stream grpc", phase: .stream, requestProtocol: "grpc", response: nil, protocols: [.grpc],
                    item: ScriptFixtures.grpcMessage("{}", 1)),
            Context(name: "stream websocket", phase: .stream, requestProtocol: "websocket", response: nil, protocols: [.webSocket],
                    item: ScriptFixtures.message("{}", 1))
        ]
    }

    func testTheRuntimeImplementsExactlyWhatTheCatalogDocuments() async throws {
        for context in contexts {
            try await check(context)
        }
    }

    private func check(_ context: Context) async throws {
        var plan = Plan()
        // Reqling's own globals come first; JavaScript's built-ins, from `JSON` on, are left to JavaScriptCore.
        for global in catalog.globals.prefix(while: { $0.name != "JSON" }) {
            plan.probes.append(Probe(path: [global.name], expected: jsTypes(global), mayBeMissing: false))
        }
        walk(["rq"], type: "Reqling", context: context, mayBeMissing: false, into: &plan)
        walk(["pm"], type: "Postman", context: context, mayBeMissing: false, into: &plan)
        plan.walked.append(Walked(path: [], type: Self.globalObject))
        var limits = ScriptLimits()
        limits.consoleEntryLength = 1_000_000
        let input = ScriptFixtures.input(
            context.phase,
            [try probeScript(plan)],
            request: ScriptFixtures.request(context.requestProtocol),
            response: context.response,
            limits: limits
        )
        let run = if let item = context.item {
            await fixtures.stream(input, items: [item])
        } else {
            await fixtures.run(input, blobs: [Data(#"{"id": 7}"#.utf8)])
        }
        // A callback that isn't a stream's handler, such as `pm.sendRequest`'s, reports during the top level, so
        // each report names whose it is.
        let reports = try run.console.map { try JSONDecoder().decode(Report.self, from: Data($0.utf8)) }
        let report = try XCTUnwrap(reports.first { $0.tag == Self.topLevel }, "\(context.name): \(run.failures)")
        XCTAssertGreaterThan(plan.probes.count, 100, "\(context.name) checks too little to mean anything")
        verify(plan.probes, plan.walked, against: report, in: context.name)

        XCTAssertEqual(run.console.count, 1 + plan.handlers.count, "\(context.name): every callback runs once: \(run.callFailures)")
        for (tag, handler) in plan.handlers.enumerated() {
            let name = "\(context.name) \(handler.method.joined(separator: "."))(…)"
            let report = try XCTUnwrap(reports.first { $0.tag == tag }, "\(name) never ran")
            verify(handler.probes, handler.walked, against: report, in: name)
        }
    }

    private func verify(_ probes: [Probe], _ walked: [Walked], against report: Report, in name: String) {
        XCTAssertEqual(report.results.count, probes.count, name)
        XCTAssertEqual(report.keys.count, walked.count, name)
        for (probe, result) in zip(probes, report.results) {
            let acceptable = probe.expected + (probe.mayBeMissing ? ["missing", "null"] : [])
            XCTAssertTrue(
                acceptable.contains(result) || probe.expected.contains("any"),
                "\(name): \(probe.path.joined(separator: ".")) is \(result), not \(probe.expected)"
            )
        }
        for (item, keys) in zip(walked, report.keys) {
            let documented = Set((item.type == Self.globalObject ? catalog.globals : catalog.type(item.type)?.members ?? []).map(\.name))
            for key in keys where !documented.contains(key) {
                XCTFail("\(name): \(item.path.joined(separator: ".")).\(key) isn't in the catalog's \(item.type)")
            }
        }
    }

    /// What one context checks.
    private struct Plan {
        var probes: [Probe] = []
        var walked: [Walked] = []
        var handlers: [Handler] = []
    }

    /// Reads every probe's `typeof` and every walked object's own keys, and logs them as one JSON line; then passes
    /// each callback, which logs a line of its own, tagged with its place in the plan, when it's called.
    private func probeScript(_ plan: Plan) throws -> String {
        """
        const probes = \(try json(plan.probes))
        const walked = \(try json(plan.walked))
        const handlers = \(try json(plan.handlers))
        function read(path, root) {
          let value = root === undefined ? globalThis : root
          for (const key of path) {
            if (value === null || value === undefined) return { missing: true }
            value = value[key]
          }
          return { value }
        }
        function report(probes, walked, root, tag) {
          const results = probes.map((probe) => {
            try {
              const found = read(probe.path, root)
              if (found.missing || found.value === undefined) return 'missing'
              return found.value === null ? 'null' : typeof found.value
            } catch (error) { return 'throws: ' + error.message }
          })
          const keys = walked.map((item) => {
            try {
              const { value } = read(item.path, root)
              return value !== null && (typeof value === 'object' || typeof value === 'function') ? Object.keys(value) : []
            } catch (error) { return [] }
          })
          console.log(JSON.stringify({ tag, results, keys }))
        }
        report(probes, walked, undefined, \(Self.topLevel))
        for (const [tag, handler] of handlers.entries()) {
          const receiver = read(handler.method.slice(0, -1)).value
          const values = Array(handler.argument).fill('https://example.test/conformance')
          values.push((...parameters) => report(handler.probes, handler.walked, parameters[handler.position], tag))
          receiver[handler.method[handler.method.length - 1]](...values)
        }
        """
    }

    /// Stands for the global object among the walked types; no catalog type has the name.
    private static let globalObject = "(global object)"
    /// The top level's report's tag; a callback's is its index in the plan's handlers.
    private static let topLevel = -1

    private struct Report: Decodable {
        let tag: Int
        let results: [String]
        let keys: [[String]]
    }

    private func walk(_ path: [String], type name: String, context: Context, mayBeMissing: Bool, into plan: inout Plan) {
        guard let type = catalog.type(name), !type.isOpen else {
            return
        }
        plan.walked.append(Walked(path: path, type: name))
        for member in type.members where member.applies(to: context.phase, protocols: context.protocols) {
            let memberPath = path + [member.name]
            if case .unsupported = member.availability {
                plan.probes.append(Probe(path: memberPath, expected: ["function", "object"], mayBeMissing: false))
                continue
            }
            if member.type == .void, !member.isMethod {
                continue
            }
            plan.probes.append(Probe(path: memberPath, expected: jsTypes(member), mayBeMissing: mayBeMissing))
            if let functionType = member.functionType {
                walk(memberPath, type: functionType, context: context, mayBeMissing: mayBeMissing, into: &plan)
            }
            plan.handlers += handlers(of: member, at: memberPath, context: context)
            guard !member.isMethod else {
                continue
            }
            switch member.type {
            case .named(let child):
                walk(memberPath, type: child, context: context, mayBeMissing: mayBeMissing, into: &plan)
            case .optional(let wrapped):
                if let child = wrapped.namedType {
                    walk(memberPath, type: child, context: context, mayBeMissing: true, into: &plan)
                }
            case .array(let element):
                if let child = element.namedType {
                    walk(memberPath + ["0"], type: child, context: context, mayBeMissing: true, into: &plan)
                }
            default:
                break
            }
        }
    }

    /// What the probe passes each callback `member` takes, checking the callback's first parameter of a named type, as
    /// `pm.sendRequest`'s gets an error before the response.
    private func handlers(of member: ScriptMember, at path: [String], context: Context) -> [Handler] {
        member.parameters.enumerated().compactMap { index, parameter in
            guard case .callback(let arguments) = parameter.type else {
                return nil
            }
            let position = arguments.firstIndex { $0.type.namedType != nil } ?? 0
            var handler = Plan()
            if let argument = arguments.indices.contains(position) ? arguments[position].type.namedType : nil {
                walk([], type: argument, context: context, mayBeMissing: false, into: &handler)
            }
            return Handler(method: path, argument: index, position: position, probes: handler.probes, walked: handler.walked)
        }
    }

    /// The `typeof` results a member may give. A named type may be a callable object, as lodash's `_` is.
    private func jsTypes(_ member: ScriptMember) -> [String] {
        member.isMethod ? ["function"] : jsTypes(member.type)
    }

    private func jsTypes(_ type: ScriptValueType) -> [String] {
        switch type {
        case .string: ["string"]
        case .number: ["number"]
        case .boolean: ["boolean"]
        case .function, .callback: ["function"]
        case .any, .responseJSON: ["any"]
        // Present but empty, as a text message's `base64` is; never missing.
        case .optional(let wrapped): jsTypes(wrapped) + ["null"]
        case .named: ["object", "function"]
        case .object, .array, .promise, .void: ["object"]
        case .oneOf(let types): types.flatMap(jsTypes)
        }
    }

    private func json(_ value: some Encodable) throws -> String {
        try XCTUnwrap(String(bytes: try JSONEncoder().encode(value), encoding: .utf8))
    }
}

/// The catalog's own consistency, and the vendored libraries' integrity.
final class ScriptAPICatalogTests: XCTestCase {
    func testEveryNamedTypeExistsAndEveryMemberIsDescribed() {
        let catalog = ScriptAPICatalog.standard
        var referenced: [String] = []
        for member in catalog.globals + catalog.types.values.flatMap(\.members) {
            XCTAssertFalse(member.summary.isEmpty, member.name)
            referenced += member.type.referencedNames + [member.functionType].compactMap { $0 }
            for parameter in member.parameters {
                referenced += parameter.type.referencedNames
                // Parameter hints show it as a sentence under the signature.
                XCTAssertTrue(parameter.summary.hasSuffix("."), "\(member.name)(\(parameter.name)) needs a summary ending in a period")
                if case .callback(let arguments) = parameter.type {
                    for argument in arguments {
                        XCTAssertTrue(argument.summary.hasSuffix("."), "\(member.name)(\(parameter.name)) needs its arguments described")
                    }
                }
            }
        }
        for name in referenced {
            XCTAssertNotNil(catalog.type(name), "\(name) is referenced but not in the catalog")
        }
    }

    /// Members that share a name differ by protocol (`rq.onMessage`, `rq.response.messages`), so in any phase where
    /// both apply, one protocol never has two of them to choose between.
    func testMembersSharingANameNeverOverlap() {
        for type in ScriptAPICatalog.standard.types.values {
            let byName = Dictionary(grouping: type.members, by: \.name)
            for (name, members) in byName where members.count > 1 {
                for (index, first) in members.enumerated() {
                    for second in members.dropFirst(index + 1) where !first.phases.isDisjoint(with: second.phases) {
                        let disjoint = first.protocols.flatMap { mine in second.protocols.map { mine.isDisjoint(with: $0) } } ?? false
                        XCTAssertTrue(disjoint, "\(type.name).\(name) has two members for one protocol and phase")
                    }
                }
            }
        }
    }

    func testEveryPostmanMemberNamesItsEquivalentOrWhyItIsUnsupported() throws {
        let catalog = ScriptAPICatalog.standard
        // Postman's response assertions have no `rq` equivalent: `rq.expect` covers them.
        let assertions: Set<String> = ["PostmanAssertion", "PostmanNegatedAssertion", "PostmanHave", "PostmanBe"]
        let postman = catalog.types.values.filter { $0.name.hasPrefix("Postman") && !assertions.contains($0.name) }
        for member in postman.flatMap(\.members) {
            XCTAssertNotEqual(member.availability, .supported, "\(member.name) should name its rq equivalent")
        }
    }

    func testTheVendoredLibrariesMatchTheirManifest() throws {
        let vendor = ScriptFixtures.runtime.appendingPathComponent("vendor")
        let manifestData = try Data(contentsOf: vendor.appendingPathComponent("manifest.json"))
        let manifest = try JSONDecoder().decode([String: VendoredLibrary].self, from: manifestData)

        XCTAssertEqual(Set(manifest.keys), ["crypto-js", "lodash"])
        // `require`'s choices are what the editor warns against, so they must be exactly what the runner loads.
        let require = try XCTUnwrap(ScriptAPICatalog.standard.globals.first { $0.name == "require" })
        guard case .choices(let choices, exhaustive: true, matchesCase: true)? = require.parameters.first?.completion else {
            return XCTFail("require should take exactly its vendored libraries' names")
        }
        XCTAssertEqual(Set(choices), Set(manifest.keys))
        for (name, library) in manifest {
            let data = try Data(contentsOf: vendor.appendingPathComponent(library.file))
            XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), library.sha256, name)
            XCTAssertTrue(FileManager.default.fileExists(atPath: vendor.appendingPathComponent(library.license).path), name)
        }
    }

    private struct VendoredLibrary: Decodable {
        let file: String
        let license: String
        let sha256: String
    }
}
