import Foundation
import JavaScriptCore
import ReqlingScriptProtocol

/// The Swift functions `runtime.js` builds `rq`, `console`, timers, crypto, and `require` from, installed as
/// `__native`, which the runtime captures and then deletes, so scripts only reach them through `rq`. Arguments arrive
/// as strings the runtime already converted. A failing call throws into the script by setting the context's
/// exception (`fail`).
extension ScriptLevelHost {
    func installNatives() {
        guard let native = JSValue(newObjectIn: context) else {
            return
        }
        installReporting(on: native)
        installVariables(on: native)
        installFlow(on: native)
        installRequest(on: native)
        installResponse(on: native)
        installCrypto(on: native)
        installCookies(on: native)
        installStream(on: native)
        installFetch(on: native)
        installRuntime(on: native)
        context.setObject(native, forKeyedSubscript: "__native" as NSString)
    }

    private func installReporting(on native: JSValue) {
        let info: @convention(block) () -> [String: Any] = { [unowned self] in
            let input = phase.input
            return [
                "phase": input.phase.rawValue,
                "level": level.kind.rawValue,
                "levelName": level.name,
                "requestName": input.info.requestName,
                "requestId": input.info.requestID,
                "protocol": input.info.protocolName,
                "environment": input.info.environmentName,
                "defaultEnvironment": input.info.defaultEnvironmentName,
                "iteration": input.info.iteration,
                "iterationCount": input.info.iterationCount
            ]
        }
        let log: @convention(block) (String, String) -> Void = { [unowned self] severity, text in
            phase.reporter.console(level: index, severity: ScriptConsoleSeverity(rawValue: severity) ?? .log, text: text)
        }
        let test: @convention(block) (String, String, JSValue) -> Void = { [unowned self] name, result, message in
            let text = message.isUndefined || message.isNull ? nil : message.toString()
            phase.reporter.test(level: index, name: name, result: ScriptTestResult(rawValue: result) ?? .failed, message: text)
        }
        let settled: @convention(block) (JSValue) -> Void = { [unowned self] error in
            settle(error)
        }
        set(native, "info", info)
        set(native, "log", log)
        set(native, "test", test)
        set(native, "settled", settled)
    }

    private func installVariables(on native: JSValue) {
        let variables = phase.variables
        let get: @convention(block) (String, String) -> JSValue = { [unowned self] scope, key in
            guard let scope = ScriptVariables.Scope(rawValue: scope), let value = variables.get(scope, key) else {
                return JSValue(undefinedIn: context)
            }
            return JSValue(object: value.value, in: context)
        }
        let isSecret: @convention(block) (String, String) -> Bool = { scope, key in
            ScriptVariables.Scope(rawValue: scope).map { variables.isSecret($0, key) } ?? false
        }
        let values: @convention(block) (String) -> [String: String] = { scope in
            ScriptVariables.Scope(rawValue: scope).map(variables.values) ?? [:]
        }
        let setValue: @convention(block) (String, String, JSValue, Bool) -> Void = { [unowned self] scope, key, value, secret in
            guard let scope = ScriptVariables.Scope(rawValue: scope) else {
                return
            }
            do throws(ScriptFailure) {
                try variables.set(scope, key, value: value.isNull || value.isUndefined ? nil : value.toString(), secret: secret)
            } catch {
                fail(error.message)
            }
        }
        let replaceIn: @convention(block) (String) -> String = { text in
            variables.replaceIn(text)
        }
        let dataGet: @convention(block) (String) -> JSValue = { [unowned self] key in
            guard let value = variables.layers.iterationData[key] else {
                return JSValue(undefinedIn: context)
            }
            return JSValue(object: value, in: context)
        }
        let dataValues: @convention(block) () -> [String: String] = {
            variables.layers.iterationData
        }
        set(native, "varGet", get)
        set(native, "varIsSecret", isSecret)
        set(native, "varValues", values)
        set(native, "varSet", setValue)
        set(native, "replaceIn", replaceIn)
        set(native, "dataGet", dataGet)
        set(native, "dataValues", dataValues)
    }

    /// `rq.execution`; the runtime checks the phase and the argument first.
    private func installFlow(on native: JSValue) {
        let skipRequest: @convention(block) () -> Void = { [unowned self] in
            phase.skipRequest()
        }
        let setNextRequest: @convention(block) (JSValue) -> Void = { [unowned self] request in
            phase.setNextRequest(request.isNull ? nil : request.toString())
        }
        set(native, "skipRequest", skipRequest)
        set(native, "setNextRequest", setNextRequest)
    }

    private func installRequest(on native: JSValue) {
        let request = phase.request
        let snapshot: @convention(block) () -> [String: Any] = {
            Self.description(of: request.snapshot)
        }
        let rows: @convention(block) (String) -> [[String]] = { target in
            ScriptRequestChange.Target(rawValue: target).map { ScriptResponseAccess.rows(request.rows($0)) } ?? []
        }
        let change: @convention(block) (String, String, String, JSValue) -> Void = { [unowned self] operation, target, name, value in
            guard let operation = ScriptRequestChange.Operation(rawValue: operation),
                  let target = ScriptRequestChange.Target(rawValue: target) else {
                return
            }
            let text = value.isNull || value.isUndefined ? nil : value.toString()
            do throws(ScriptFailure) {
                try request.apply(ScriptRequestChange(operation: operation, target: target, name: name, value: text))
            } catch {
                fail(error.message)
            }
        }
        set(native, "request", snapshot)
        set(native, "requestRows", rows)
        set(native, "requestChange", change)
    }

    private func installResponse(on native: JSValue) {
        let response: @convention(block) () -> JSValue = { [unowned self] in
            guard let response = phase.response else {
                return JSValue(nullIn: context)
            }
            return JSValue(object: response.object, in: context)
        }
        let responseText: @convention(block) () -> String = { [unowned self] in
            phase.response?.bodyText ?? ""
        }
        let responseBase64: @convention(block) () -> String = { [unowned self] in
            phase.response?.body.base64EncodedString() ?? ""
        }
        set(native, "response", response)
        set(native, "responseText", responseText)
        set(native, "responseBase64", responseBase64)
    }

    /// A stream script's handler failures and `rq.send`; the runtime checks the phase and turns the script's value
    /// into text or an `ArrayBuffer` first.
    private func installStream(on native: JSValue) {
        let handlerFailed: @convention(block) (JSValue) -> Void = { [unowned self] error in
            handlerFailed(error)
        }
        let sendText: @convention(block) (String) -> Void = { [unowned self] text in
            report(.text(text))
        }
        let sendBinary: @convention(block) (JSValue) -> Void = { [unowned self] buffer in
            guard let bytes = arrayBufferBytes(buffer) else {
                fail("rq.send couldn't read the message's bytes.")
                return
            }
            report(.binary(bytes))
        }
        set(native, "handlerFailed", handlerFailed)
        set(native, "send", sendText)
        set(native, "sendBinary", sendBinary)
    }

    /// `rq.sendRequest` and `rq.runRequest`; the runtime normalizes their arguments to text first, and keeps the
    /// promise each settles (`finishFetch`). Each returns the fetch's ID, or `undefined` after throwing.
    private func installFetch(on native: JSValue) {
        typealias Send = @convention(block) (String, String, JSValue, JSValue, JSValue, JSValue) -> JSValue
        let send: Send = { [unowned self] method, url, headers, text, binary, timeout in
            var body: Data?
            if !binary.isNull, !binary.isUndefined {
                guard let bytes = arrayBufferBytes(binary) else {
                    fail("rq.sendRequest couldn't read the body's bytes.")
                    return JSValue(undefinedIn: context)
                }
                body = bytes
            } else if !text.isNull, !text.isUndefined {
                body = Data((text.toString() ?? "").utf8)
            }
            let rows = (headers.toArray() ?? []).compactMap { row -> ScriptRow? in
                guard let pair = row as? [Any], pair.count == 2 else {
                    return nil
                }
                return ScriptRow(name: String(describing: pair[0]), value: String(describing: pair[1]))
            }
            let seconds = timeout.isNumber ? timeout.toDouble() / 1_000 : nil
            return startFetch(.send(ScriptFetchRequest(method: method, url: url, headers: rows, body: body, timeoutSeconds: seconds)))
        }
        let run: @convention(block) (String, JSValue) -> JSValue = { [unowned self] request, variables in
            var values: [String: String] = [:]
            for (key, value) in variables.toDictionary() ?? [:] {
                values[String(describing: key)] = String(describing: value)
            }
            return startFetch(.run(request: request, variables: values))
        }
        let text: @convention(block) (Int) -> String = { [unowned self] id in
            // `text()` decodes as browsers do, one bad byte becoming U+FFFD, rather than losing the body.
            // swiftlint:disable:next optional_data_string_conversion
            String(decoding: fetchBody(id), as: UTF8.self)
        }
        let base64: @convention(block) (Int) -> String = { [unowned self] id in
            fetchBody(id).base64EncodedString()
        }
        set(native, "fetchSend", send)
        set(native, "fetchRun", run)
        set(native, "fetchText", text)
        set(native, "fetchBase64", base64)
    }

    private func startFetch(_ fetch: ScriptFetch) -> JSValue {
        do throws(ScriptFailure) {
            let id = try phase.fetch(fetch, level: index)
            expectFetch(id)
            return JSValue(int32: Int32(id), in: context)
        } catch {
            fail(error.message)
            return JSValue(undefinedIn: context)
        }
    }

    private func report(_ message: ScriptOutgoingMessage) {
        do throws(ScriptFailure) {
            try phase.send(message, level: index)
        } catch {
            fail(error.message)
        }
    }

    /// An `ArrayBuffer`'s bytes, through JavaScriptCore's public C API, which reads them without converting each byte
    /// to a number.
    private func arrayBufferBytes(_ value: JSValue) -> Data? {
        guard let context = context.jsGlobalContextRef, let reference = value.jsValueRef,
              JSValueGetTypedArrayType(context, reference, nil) == kJSTypedArrayTypeArrayBuffer,
              let object = JSValueToObject(context, reference, nil) else {
            return nil
        }
        let length = JSObjectGetArrayBufferByteLength(context, object, nil)
        guard length > 0 else {
            return Data()
        }
        guard let bytes = JSObjectGetArrayBufferBytesPtr(context, object, nil) else {
            return nil
        }
        return Data(bytes: bytes, count: length)
    }

    /// What `runtime.js` builds `rq.request` from; absent values are `null`.
    private static func description(of snapshot: ScriptRequestSnapshot) -> [String: Any] {
        var description: [String: Any] = [
            "protocol": snapshot.protocolName,
            "method": ScriptResponseAccess.nullable(snapshot.method),
            "url": snapshot.url,
            "service": ScriptResponseAccess.nullable(snapshot.service),
            "rpc": ScriptResponseAccess.nullable(snapshot.rpc),
            "messages": snapshot.messages,
            "body": NSNull()
        ]
        if let body = snapshot.body {
            let graphQL: Any = body.mode == "graphQL" ? [
                "query": body.graphQLQuery ?? "",
                "variables": body.graphQLVariables ?? "",
                "operationName": ScriptResponseAccess.nullable(body.graphQLOperationName)
            ] as [String: Any] : NSNull()
            description["body"] = [
                "mode": body.mode,
                "raw": ScriptResponseAccess.nullable(body.raw),
                "fields": ScriptResponseAccess.rows(body.fields),
                "graphQL": graphQL
            ] as [String: Any]
        }
        return description
    }

    private func installCrypto(on native: JSValue) {
        let digest: @convention(block) (String, String, String, String) -> JSValue = { [unowned self] algorithm, data, input, output in
            attempt { () throws(ScriptFailure) -> String in
                try ScriptCrypto.text(ScriptCrypto.digest(algorithm, of: ScriptCrypto.bytes(data, encoding: input)), encoding: output)
            }
        }
        typealias HMAC = @convention(block) (String, String, String, String, String, String) -> JSValue
        let hmac: HMAC = { [unowned self] algorithm, key, keyEncoding, data, input, output in
            attempt { () throws(ScriptFailure) -> String in
                let keyBytes = try ScriptCrypto.bytes(key, encoding: keyEncoding)
                let message = try ScriptCrypto.bytes(data, encoding: input)
                return try ScriptCrypto.text(ScriptCrypto.hmac(algorithm, key: keyBytes, data: message), encoding: output)
            }
        }
        let randomBytes: @convention(block) (Int) -> [Int] = { count in
            ScriptCrypto.randomBytes(min(count, 65_536)).map(Int.init)
        }
        let uuid: @convention(block) () -> String = {
            UUID().uuidString.lowercased()
        }
        let btoa: @convention(block) (String) -> JSValue = { [unowned self] text in
            attempt { () throws(ScriptFailure) -> String in
                guard let encoded = ScriptCrypto.base64(latin1: text) else {
                    throw ScriptFailure("btoa: the text has a character outside Latin-1; encode it as UTF-8 first.")
                }
                return encoded
            }
        }
        let atob: @convention(block) (String) -> JSValue = { [unowned self] text in
            attempt { () throws(ScriptFailure) -> String in
                guard let decoded = ScriptCrypto.latin1(base64: text) else {
                    throw ScriptFailure("atob: the text isn't valid base64.")
                }
                return decoded
            }
        }
        set(native, "digest", digest)
        set(native, "hmac", hmac)
        set(native, "randomBytes", randomBytes)
        set(native, "uuid", uuid)
        set(native, "btoa", btoa)
        set(native, "atob", atob)
    }

    private func installRuntime(on native: JSValue) {
        let setTimer: @convention(block) (JSValue, Double, Bool) -> Int = { [unowned self] callback, delay, repeats in
            timers.add(callback, delayMilliseconds: delay, repeats: repeats)
        }
        let clearTimer: @convention(block) (Int) -> Void = { [unowned self] id in
            timers.clear(id)
        }
        let loadLibrary: @convention(block) (String) -> JSValue = { [unowned self] name in
            attempt { () throws(ScriptFailure) -> String in
                guard let source = phase.runtime.library(named: name) else {
                    let available = ScriptRuntimeFiles.libraries.keys.sorted().joined(separator: ", ")
                    throw ScriptFailure("require(\"\(name)\") isn't available in Reqling scripts. Available: \(available).")
                }
                return source
            }
        }
        set(native, "setTimer", setTimer)
        set(native, "clearTimer", clearTimer)
        set(native, "loadLibrary", loadLibrary)
    }

    /// The string `body` returns, or `undefined` after throwing what it threw into the script.
    func attempt(_ body: () throws(ScriptFailure) -> String) -> JSValue {
        do {
            return JSValue(object: try body(), in: context)
        } catch {
            fail(error.message)
            return JSValue(undefinedIn: context)
        }
    }

    /// Throws `message` into the script as an `Error` when the native call returns.
    func fail(_ message: String) {
        context.exception = JSValue(newErrorFromMessage: message, in: context)
    }

    func set(_ native: JSValue, _ name: String, _ block: Any) {
        native.setObject(block, forKeyedSubscript: name as NSString)
    }
}
