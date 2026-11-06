/// Gathers every value a run's scripts made secret, for output built outside the run. MCP masks with the project's
/// secrets as they stood before the run, which miss a value a script made secret, such as a run-local signature that
/// is never stored anywhere.
@MainActor
final class ScriptSecretSink {
    private(set) var values: Set<String> = []

    func collect(_ secrets: Set<String>) {
        values.formUnion(secrets)
    }

    /// `mask` with the collected secrets masked first, since they are usually the longer values: a stored secret inside
    /// one, masked first, would leave the rest of it showing.
    func masking(_ mask: @escaping (String) -> String) -> (String) -> String {
        let redaction = SecretRedaction(secrets: values)
        return { mask(redaction.apply($0)) }
    }
}
