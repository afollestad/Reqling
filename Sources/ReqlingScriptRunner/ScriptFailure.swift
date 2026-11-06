/// A message a native call throws into the script as an `Error`.
struct ScriptFailure: Error {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}
