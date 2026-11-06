import CryptoKit
import Foundation
@testable import ReqlingKit
import ReqlingScriptProtocol
import ReqlingTemplating
import XCTest

/// `ScriptAPICatalog` against the runtime the helper runs, both ways, in every phase and for every protocol: each
/// member the catalog says applies exists with its declared type, and each key the runtime exposes on `rq`, `pm`, and
/// what they hold is in the catalog. One helper launch per context checks every path at once.
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
            )), protocols: [.webSocket])
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
        let run = await fixtures.run(
            ScriptFixtures.input(
                context.phase,
                [try probeScript(plan)],
                request: ScriptFixtures.request(context.requestProtocol),
                response: context.response,
                limits: limits
            ),
            blobs: [Data(#"{"id": 7}"#.utf8)]
        )
        let output = try XCTUnwrap(run.console.first, "\(context.name): \(run.failures)")
        let report = try JSONDecoder().decode(Report.self, from: Data(output.utf8))
        XCTAssertEqual(report.results.count, plan.probes.count, context.name)
        XCTAssertEqual(report.keys.count, plan.walked.count, context.name)
        XCTAssertGreaterThan(plan.probes.count, 100, "\(context.name) checks too little to mean anything")

        for (probe, result) in zip(plan.probes, report.results) {
            let acceptable = probe.expected + (probe.mayBeMissing ? ["missing", "null"] : [])
            XCTAssertTrue(
                acceptable.contains(result) || probe.expected.contains("any"),
                "\(context.name): \(probe.path.joined(separator: ".")) is \(result), not \(probe.expected)"
            )
        }
        for (item, keys) in zip(plan.walked, report.keys) {
            let documented = Set((item.type == Self.globalObject ? catalog.globals : catalog.type(item.type)?.members ?? []).map(\.name))
            for key in keys where !documented.contains(key) {
                XCTFail("\(context.name): \(item.path.joined(separator: ".")).\(key) isn't in the catalog's \(item.type)")
            }
        }
    }

    /// What one context checks.
    private struct Plan {
        var probes: [Probe] = []
        var walked: [Walked] = []
    }

    /// Reads every probe's `typeof` and every walked object's own keys, and logs them as one JSON line.
    private func probeScript(_ plan: Plan) throws -> String {
        """
        const probes = \(try json(plan.probes))
        const walked = \(try json(plan.walked))
        function read(path) {
          let value = globalThis
          for (const key of path) {
            if (value === null || value === undefined) return { missing: true }
            value = value[key]
          }
          return { value }
        }
        const results = probes.map((probe) => {
          try {
            const found = read(probe.path)
            if (found.missing || found.value === undefined) return 'missing'
            return found.value === null ? 'null' : typeof found.value
          } catch (error) { return 'throws: ' + error.message }
        })
        const keys = walked.map((item) => {
          try {
            const { value } = read(item.path)
            return value !== null && (typeof value === 'object' || typeof value === 'function') ? Object.keys(value) : []
          } catch (error) { return [] }
        })
        console.log(JSON.stringify({ results, keys }))
        """
    }

    /// Stands for the global object among the walked types; no catalog type has the name.
    private static let globalObject = "(global object)"

    private struct Report: Decodable {
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

    /// The `typeof` results a member may give. A named type may be a callable object, as lodash's `_` is.
    private func jsTypes(_ member: ScriptMember) -> [String] {
        member.isMethod ? ["function"] : jsTypes(member.type)
    }

    private func jsTypes(_ type: ScriptValueType) -> [String] {
        switch type {
        case .string: ["string"]
        case .number: ["number"]
        case .boolean: ["boolean"]
        case .function: ["function"]
        case .any, .responseJSON: ["any"]
        case .optional(let wrapped): jsTypes(wrapped)
        case .named: ["object", "function"]
        case .object, .array, .promise, .void: ["object"]
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
            referenced += [member.type.namedType, member.functionType].compactMap { $0 }
            if case .array(let element) = member.type, let name = element.namedType {
                referenced.append(name)
            }
            for parameter in member.parameters {
                referenced += parameter.type.namedType.map { [$0] } ?? []
            }
        }
        for name in referenced {
            XCTAssertNotNil(catalog.type(name), "\(name) is referenced but not in the catalog")
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
