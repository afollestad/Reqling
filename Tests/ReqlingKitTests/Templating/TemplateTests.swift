import Foundation
import ReqlingKit
import ReqlingTemplating
import Synchronization
import XCTest

final class TemplateParserTests: XCTestCase {
    func testFindsTokensWithTrimmedNamesAndUTF16Ranges() {
        let text = "é{{ host }}/{{$uuid}}"
        let tokens = TemplateParser.tokens(in: text)

        XCTAssertEqual(tokens.map(\.name), ["host", "$uuid"])
        XCTAssertEqual(tokens.map(\.kind), [.variable, .dynamic])
        XCTAssertEqual(tokens.map(\.utf16Range), [NSRange(location: 1, length: 10), NSRange(location: 12, length: 9)])
    }

    func testAdjacentTokensAndExtraBraces() {
        XCTAssertEqual(TemplateParser.tokens(in: "{{a}}{{b}}").map(\.name), ["a", "b"])
        XCTAssertEqual(TemplateParser.tokens(in: "{{{a}}}").map(\.name), ["a"])
        XCTAssertEqual(TemplateParser.tokens(in: "{{{a}}}").first.map { NSRange($0.range, in: "{{{a}}}") }, NSRange(location: 1, length: 5))
    }

    func testIgnoresUnterminatedEmptyAndMultilineReferences() {
        XCTAssertTrue(TemplateParser.tokens(in: "{{open").isEmpty)
        XCTAssertTrue(TemplateParser.tokens(in: "{{ }}").isEmpty)
        XCTAssertTrue(TemplateParser.tokens(in: "{{a\nb}}").isEmpty)
        XCTAssertEqual(TemplateParser.tokens(in: "{{a} b}} {{c}}").map(\.name), ["c"])
    }

    /// Many `{{` before a distant `}}` once rescanned to the `}}` from every `{{`, which is quadratic.
    func testUnclosedReferencesBeforeADistantCloseStayLinear() {
        let text = String(repeating: "{{x", count: 50_000) + "}}"

        XCTAssertEqual(TemplateParser.tokens(in: text).map(\.name), ["x"])
        XCTAssertTrue(TemplateParser.tokens(in: String(repeating: "{{a\n", count: 50_000) + "}}").isEmpty)
    }

    func testOpenTokenRangeIsOnlyInsideATemplateStillOpenOnItsLine() {
        XCTAssertEqual(TemplateParser.openTokenRange(in: "{{to", cursor: 4), NSRange(location: 2, length: 2))
        XCTAssertEqual(TemplateParser.openTokenRange(in: "a/{{", cursor: 4), NSRange(location: 4, length: 0))
        XCTAssertNil(TemplateParser.openTokenRange(in: "https://x/to", cursor: 12))
        XCTAssertNil(TemplateParser.openTokenRange(in: "{{a}} b", cursor: 7))
        XCTAssertNil(TemplateParser.openTokenRange(in: "{{a\nb", cursor: 5))
    }

    func testVariableNamesAreDistinctAndSkipDynamicValues() {
        XCTAssertEqual(TemplateParser.variableNames(in: "{{b}}{{a}}{{b}}{{$uuid}}"), ["b", "a"])
    }
}

final class TemplateResolverTests: XCTestCase {
    private let fixedDynamic = DynamicVariables(
        now: { Date(timeIntervalSince1970: 1_700_000_000) },
        uuid: { UUID(uuidString: "00000000-0000-0000-0000-000000000001")! },
        randomInt: { 42 }
    )

    private func document() -> (ProjectDocument, staging: EnvironmentID) {
        let staging = RequestEnvironment(name: "Staging", variables: [
            Variable(key: "host", value: "staging.example.com"),
            Variable(key: "disabled", value: "nope", isEnabled: false)
        ])
        let document = ProjectDocument(
            name: "Scope",
            defaultEnvironment: RequestEnvironment(name: "Default", variables: [
                Variable(key: "host", value: "example.com"),
                Variable(key: "base", value: "https://{{host}}"),
                Variable(key: "token", value: "s3cr3t", isSecret: true),
                Variable(key: "disabled", value: "default")
            ]),
            environments: [staging]
        )
        return (document, staging.id)
    }

    /// A scope with an empty Global, for tests about the project's own environments.
    private func scope(_ document: ProjectDocument, active: EnvironmentID?) -> VariableScope {
        VariableScope(global: .global(), document: document, activeEnvironmentID: active)
    }

    func testTheActiveEnvironmentOverridesDefaultAndOverridesWin() {
        let (document, staging) = document()

        let defaultOnly = TemplateResolver(scope: scope(document, active: nil), dynamic: fixedDynamic)
        let onStaging = TemplateResolver(scope: scope(document, active: staging), dynamic: fixedDynamic)
        let overridden = TemplateResolver(
            scope: VariableScope(global: .global(), document: document, activeEnvironmentID: staging, overrides: ["host": "local"]),
            dynamic: fixedDynamic
        )

        XCTAssertEqual(defaultOnly.resolve("{{base}}/x").value, "https://example.com/x")
        XCTAssertEqual(onStaging.resolve("{{base}}/x").value, "https://staging.example.com/x")
        XCTAssertEqual(overridden.resolve("{{base}}/x").value, "https://local/x")
        // A disabled variable in the active environment does not hide Default's.
        XCTAssertEqual(onStaging.resolve("{{disabled}}").value, "default")
    }

    func testGlobalSitsBeneathDefault() {
        let (document, staging) = document()
        let global = RequestEnvironment.global(variables: [
            Variable(key: "host", value: "global.example.com"),
            Variable(key: "region", value: "eu"),
            Variable(key: "off", value: "hidden", isEnabled: false)
        ])

        let scope = VariableScope(global: global, document: document, activeEnvironmentID: staging, overrides: ["region": "us"])
        let defaultOnly = VariableScope(global: global, document: document, activeEnvironmentID: nil)

        // Default and the active environment override Global by key, overrides beat everything, and a disabled Global
        // variable is not there at all.
        XCTAssertEqual(scope.lookup("host")?.value, "staging.example.com")
        XCTAssertEqual(defaultOnly.lookup("host")?.value, "example.com")
        XCTAssertEqual(scope.lookup("region")?.value, "us")
        XCTAssertEqual(defaultOnly.lookup("region")?.source, .environment(id: RequestEnvironment.globalID, name: "Global"))
        XCTAssertNil(defaultOnly.lookup("off"))
    }

    func testUnresolvedNamesStayVerbatimAndAreReported() {
        let (document, _) = document()
        let resolution = TemplateResolver(scope: scope(document, active: nil), dynamic: fixedDynamic)
            .resolve("{{missing}}-{{host}}-{{missing}}-{{$nope}}")

        XCTAssertEqual(resolution.value, "{{missing}}-example.com-{{missing}}-{{$nope}}")
        XCTAssertEqual(resolution.unresolved, ["missing", "$nope"])
    }

    func testReferenceCyclesStopAndReportTheName() {
        let scope = VariableScope(entries: [
            "a": .init(value: "{{b}}", source: .override, isSecret: false),
            "b": .init(value: "{{a}}", source: .override, isSecret: false)
        ])

        let resolution = TemplateResolver(scope: scope, dynamic: fixedDynamic).resolve("{{a}}")

        XCTAssertEqual(resolution.value, "{{a}}")
        XCTAssertEqual(resolution.unresolved, ["a"])
    }

    func testMaskingHidesSecretsButStillReportsThem() {
        let (document, _) = document()
        let resolver = TemplateResolver(scope: scope(document, active: nil), dynamic: fixedDynamic)

        let masked = resolver.resolve("Bearer {{token}}", masked: true)
        let plain = resolver.resolve("Bearer {{token}}")

        XCTAssertEqual(masked.value, "Bearer \(TemplateResolver.mask)")
        XCTAssertTrue(masked.usedSecrets)
        XCTAssertEqual(plain.value, "Bearer s3cr3t")
    }

    func testDynamicVariables() {
        let resolver = TemplateResolver(scope: VariableScope(), dynamic: fixedDynamic)

        XCTAssertEqual(
            resolver.resolve("{{$uuid}} {{$timestamp}} {{$isoTimestamp}} {{$randomInt}}").value,
            "00000000-0000-0000-0000-000000000001 1700000000 2023-11-14T22:13:20Z 42"
        )
    }

    func testPlainAndMaskedTextComeFromOnePass() {
        let counter = Counter()
        let dynamic = DynamicVariables(now: { Date() }, uuid: { UUID() }, randomInt: { counter.next() })
        let scope = VariableScope(entries: ["token": .init(value: "s3cr3t-{{$randomInt}}", source: .override, isSecret: true)])

        let resolution = TemplateResolver(scope: scope, dynamic: dynamic).resolve("{{$randomInt}} {{token}}")

        XCTAssertEqual(resolution.value, "1 s3cr3t-2")
        XCTAssertEqual(resolution.maskedValue, "1 \(TemplateResolver.mask)")
    }

    func testExpansionIsBoundedEvenWhenEveryValueIsEmpty() {
        var entries: [String: VariableScope.Entry] = ["v9": .init(value: "", source: .override, isSecret: false)]
        for level in 0..<9 {
            entries["v\(level)"] = .init(value: String(repeating: "{{v\(level + 1)}}", count: 10), source: .override, isSecret: false)
        }
        let resolver = TemplateResolver(scope: VariableScope(entries: entries), dynamic: fixedDynamic)

        XCTAssertTrue(resolver.resolve("{{v0}}").exceedsLimit)
        XCTAssertFalse(resolver.resolve("{{v8}}").exceedsLimit)
    }

    /// The cap is on what substitution adds, so a large body with few variables still sends.
    func testTheTemplatesOwnTextDoesNotCountTowardTheCap() {
        let body = String(repeating: "x", count: TemplateExpansion.maximumOutputLength + 1)

        let resolution = TemplateResolver(scope: VariableScope(), dynamic: fixedDynamic).resolve(body + "{{$randomInt}}")

        XCTAssertFalse(resolution.exceedsLimit)
        XCTAssertEqual(resolution.value.utf8.count, body.utf8.count + 2)
    }
}

/// Counts up from 1, so each generated value is distinguishable.
private final class Counter: Sendable {
    private let value = Mutex(0)

    func next() -> Int {
        value.withLock { value in
            value += 1
            return value
        }
    }
}
