import Foundation

/// One template resolved once into the text sent and the text shown, as `HTTPRequestBuilder` does, so dynamic values
/// (`{{$uuid}}`) are the same in both.
struct ResolvedTemplate: Hashable, Sendable {
    let sent: String
    let shown: String
}

/// Resolves one run's templates (a gRPC call's target, metadata, and messages, or a WebSocket's messages), collecting
/// the unresolved names in first-use order across every template.
struct RunTemplates {
    let resolver: TemplateResolver
    private(set) var unresolved: [String] = []

    init(resolver: TemplateResolver) {
        self.resolver = resolver
    }

    mutating func resolve(_ text: String) throws(RunFailure) -> ResolvedTemplate {
        let resolution = resolver.resolve(text)
        guard !resolution.exceedsLimit else {
            throw RunFailure(kind: .invalidRequest, message: HTTPBuildError.templateTooLarge.localizedDescription)
        }
        for name in resolution.unresolved where !unresolved.contains(name) {
            unresolved.append(name)
        }
        return ResolvedTemplate(sent: resolution.value, shown: resolution.maskedValue)
    }
}
