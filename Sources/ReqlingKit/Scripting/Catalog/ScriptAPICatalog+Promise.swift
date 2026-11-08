import ReqlingScriptProtocol

/// A promise's own members, for whatever it settles with: `rq.sendRequest(…)` gives a `Promise<IncomingResponse>`,
/// whose `then` callback gets the response. The catalog has no generic types, so the analyzer asks for this type
/// whenever it reaches a `.promise` value; it's never in `types`, and the reference shows only `Promise<…>`.
extension ScriptAPICatalog {
    static func promiseType(settlingWith settled: ScriptValueType) -> ScriptType {
        let rejected = ScriptParameter("onRejected", .callback([ScriptParameter("error", .any, "Why it rejected.")]),
                                       "Runs with the error when the promise rejects.", isOptional: true)
        return ScriptType("Promise", "A value that arrives later; `await` gives it.", members: [
            .method("then", [
                ScriptParameter("onFulfilled", .callback([ScriptParameter("value", settled, "What the promise settled with.")]),
                                "Runs with the value once the promise settles."),
                rejected
            ], returns: .promise(.any), "Runs a callback with the value, and gives a promise of what it returns."),
            .method("catch", [rejected], returns: .promise(.any), "Runs a callback with the error if the promise rejects."),
            .method("finally", [ScriptParameter("onFinally", .function, "Runs once the promise settles, either way.")],
                    returns: .promise(settled), "Runs a callback once the promise settles, either way.")
        ])
    }
}
