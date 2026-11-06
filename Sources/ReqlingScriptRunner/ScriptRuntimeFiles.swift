import Foundation

/// The JavaScript every level evaluates before its script, read once at launch, and the vendored libraries `require`
/// loads on first use, by fixed name only, so a script can never read another file.
struct ScriptRuntimeFiles {
    /// In evaluation order: `expect.js` and `pm.js` build on what `runtime.js` defines.
    let sources: [(name: String, source: String)]
    private let directory: URL

    /// The libraries `require` knows, by the name scripts pass it.
    static let libraries = ["crypto-js": "vendor/crypto-js.js", "lodash": "vendor/lodash.min.js"]

    /// `nil` when any core file is missing or unreadable.
    init?(directory: URL) {
        var sources: [(String, String)] = []
        for name in ["runtime.js", "expect.js", "pm.js"] {
            guard let source = try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8) else {
                return nil
            }
            sources.append((name, source))
        }
        self.sources = sources
        self.directory = directory
    }

    func library(named name: String) -> String? {
        Self.libraries[name].flatMap { try? String(contentsOf: directory.appendingPathComponent($0), encoding: .utf8) }
    }
}
