import ReqlingTemplating
import XCTest

final class VariableLayersTests: XCTestCase {
    private func variable(_ value: String, secret: Bool = false) -> TemplateVariable {
        TemplateVariable(value: value, isSecret: secret)
    }

    /// Every layer defines `key`; removing the winner each time walks the whole order.
    func testPrecedenceRunsFromLocalDownToGlobalSaved() {
        var layers = VariableLayers(
            global: VariableLayer(saved: ["key": variable("global saved")], current: ["key": .value(variable("global current"))]),
            defaultEnvironment: VariableLayer(saved: ["key": variable("default saved")], current: ["key": .value(variable("default current"))]),
            active: VariableLayer(saved: ["key": variable("active saved")], current: ["key": .value(variable("active current"))]),
            overrides: ["key": "override"],
            local: ["key": variable("local")]
        )
        var seen: [String] = []
        while let found = layers.lookup("key") {
            seen.append(found.variable.value)
            switch found.layer {
            case .local: layers.local["key"] = nil
            case .override: layers.overrides["key"] = nil
            case .activeEnvironment where found.isCurrentValue: layers.active?.current["key"] = nil
            case .activeEnvironment: layers.active?.saved["key"] = nil
            case .defaultEnvironment where found.isCurrentValue: layers.defaultEnvironment.current["key"] = nil
            case .defaultEnvironment: layers.defaultEnvironment.saved["key"] = nil
            case .global where found.isCurrentValue: layers.global.current["key"] = nil
            case .global: layers.global.saved["key"] = nil
            }
        }

        XCTAssertEqual(seen, [
            "local", "override", "active current", "active saved", "default current", "default saved", "global current", "global saved"
        ])
    }

    func testAMarkerHidesOnlyItsOwnLayersSavedValue() {
        let layers = VariableLayers(
            defaultEnvironment: VariableLayer(saved: ["token": variable("from default")]),
            active: VariableLayer(saved: ["token": variable("from staging"), "only": variable("x")], current: ["token": .unset, "only": .unset])
        )

        XCTAssertEqual(layers.lookup("token")?.variable.value, "from default")
        XCTAssertEqual(layers.lookup("token")?.layer, .defaultEnvironment)
        XCTAssertNil(layers.lookup("only"))
        XCTAssertNil(layers.flattened()["only"])
        XCTAssertNil(layers.active?.value(for: "token"))
    }

    func testFlattenedIncludesCurrentOnlyKeysAndMarksThem() {
        let layers = VariableLayers(global: VariableLayer(current: ["fresh": .value(variable("new"))]))

        let flattened = layers.flattened()

        XCTAssertEqual(flattened["fresh"]?.variable.value, "new")
        XCTAssertEqual(flattened["fresh"]?.isCurrentValue, true)
    }

    func testEnvironmentWritesLandInDefaultWhileDefaultIsActive() {
        var layers = VariableLayers()

        layers.apply(VariableWrite(scope: .environment, key: "a", value: "1"))

        XCTAssertEqual(layers.defaultEnvironment.current["a"], .value(variable("1")))
    }

    func testEnvironmentWritesLandInTheActiveEnvironmentAndUnsetLeavesAMarker() {
        var layers = VariableLayers(active: VariableLayer(saved: ["a": variable("saved")]))

        layers.apply(VariableWrite(scope: .environment, key: "a", value: nil))
        layers.apply(VariableWrite(scope: .local, key: "b", value: "run"))
        layers.apply(VariableWrite(scope: .local, key: "b", value: nil))

        XCTAssertEqual(layers.active?.current["a"], .unset)
        XCTAssertTrue(layers.defaultEnvironment.current.isEmpty)
        XCTAssertNil(layers.local["b"])
    }

    func testAKeyThatIsSecretInScopeOrInItsLayerStaysSecret() {
        var layers = VariableLayers(
            defaultEnvironment: VariableLayer(saved: ["token": variable("abc123", secret: true)]),
            // A disabled secret row: no saved value, but its key is still secret.
            active: VariableLayer(secretKeys: ["apiKey"])
        )

        let token = layers.apply(VariableWrite(scope: .environment, key: "token", value: "new"))
        let apiKey = layers.apply(VariableWrite(scope: .environment, key: "apiKey", value: "k"))
        let plain = layers.apply(VariableWrite(scope: .environment, key: "userId", value: "42"))

        XCTAssertTrue(token.isSecret)
        XCTAssertTrue(apiKey.isSecret)
        XCTAssertFalse(plain.isSecret)
    }

    func testASecretCurrentValueIsNeverDowngraded() {
        var layers = VariableLayers()
        layers.apply(VariableWrite(scope: .global, key: "token", value: "first", isSecret: true))

        let again = layers.apply(VariableWrite(scope: .global, key: "token", value: "second"))

        XCTAssertTrue(again.isSecret)
        XCTAssertEqual(layers.global.current["token"], .value(variable("second", secret: true)))
    }

    func testTheLeakGuardMarksValuesHoldingASecret() {
        var layers = VariableLayers(
            defaultEnvironment: VariableLayer(saved: ["token": variable("S3cr3t", secret: true), "pin": variable("12", secret: true)])
        )

        let header = layers.apply(VariableWrite(scope: .environment, key: "auth", value: "Bearer s3cr3t"))
        let short = layers.apply(VariableWrite(scope: .local, key: "note", value: "room 12"))

        XCTAssertTrue(header.isSecret)
        XCTAssertFalse(short.isSecret, "Values under the minimum length never count as found secrets")
    }

    func testAllSecretValuesCoverSavedCurrentAndLocalSecrets() {
        var layers = VariableLayers(global: VariableLayer(saved: ["a": variable("saved-secret", secret: true), "b": variable("plain")]))
        layers.apply(VariableWrite(scope: .global, key: "c", value: "current-secret", isSecret: true))
        layers.apply(VariableWrite(scope: .local, key: "d", value: "local-secret", isSecret: true))

        XCTAssertEqual(layers.allSecretValues, ["saved-secret", "current-secret", "local-secret"])
    }
}
