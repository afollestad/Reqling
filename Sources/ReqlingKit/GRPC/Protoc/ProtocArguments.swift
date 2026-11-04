import Foundation

/// Builds protoc's argument list from paths a shared project file controls, refusing anything protoc could read as
/// something other than a path.
///
/// protoc has no `--` terminator: an input starting with `-` is an option (`-o<file>` writes anywhere) and one
/// starting with `@` names a response file of more options. Directories go in the joined `--proto_path=` form, so
/// their value is never parsed on its own, and may contain neither `:`, which protoc splits proto paths on, nor `=`,
/// which it reads as a virtual-path mapping.
enum ProtocArguments {
    /// Why `path` cannot be an entry file, or `nil` when it is a plain root-relative path.
    static func problem(withEntry path: String) -> String? {
        if path.isEmpty {
            return "it is empty"
        }
        if path.hasPrefix("-") || path.hasPrefix("@") {
            return "it starts with “\(path.prefix(1))”, which protoc reads as an option"
        }
        if path.hasPrefix("/") {
            return "it is absolute; entry files are relative to a proto folder"
        }
        if path.contains("\\") {
            return "it contains a backslash"
        }
        if containsControlCharacter(path) {
            return "it contains a control character"
        }
        if path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) {
            return "it has an empty, “.”, or “..” component"
        }
        return nil
    }

    /// Why `directory` cannot be passed as `--proto_path`, or `nil` when it is safe.
    static func problem(withDirectory directory: URL) -> String? {
        let path = directory.path
        if !path.hasPrefix("/") {
            return "it is not an absolute path"
        }
        if path.contains(":") || path.contains("=") {
            return "protoc cannot use a folder whose path contains “:” or “=”"
        }
        if containsControlCharacter(path) {
            return "it contains a control character"
        }
        return nil
    }

    static func protoPath(_ directory: URL) -> String {
        "--proto_path=\(directory.path)"
    }

    static func descriptorSetOut(_ file: URL) -> String {
        "--descriptor_set_out=\(file.path)"
    }

    /// A rejected path, quoted with control characters escaped so the diagnostic itself stays one readable line.
    static func diagnostic(for path: String, _ problem: String, severity: ProtocDiagnostic.Severity = .error) -> ProtocDiagnostic {
        ProtocDiagnostic(severity: severity, message: "Skipped \(path.debugDescription): \(problem).")
    }

    /// Only general category `Cc` (newlines, tabs, NUL). `CharacterSet.controlCharacters` also holds format
    /// characters, which ordinary names use: ZWNJ in Persian and Hindi, ZWJ in emoji sequences, soft hyphens.
    private static func containsControlCharacter(_ path: String) -> Bool {
        path.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }
}
