import Foundation

/// A release version as `major.minor.patch`, optionally prefixed with `v` as tags are. Anything else (a prerelease
/// suffix, a fourth component) does not parse, so such a tag never becomes an update.
public struct AppUpdateVersion: Comparable, Equatable, Hashable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init?(string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.dropFirstIfVersionPrefix()
        let parts = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let major = Int(parts[0]),
              let minor = Int(parts[1]),
              let patch = Int(parts[2]),
              major >= 0,
              minor >= 0,
              patch >= 0 else {
            return nil
        }

        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public var description: String {
        "\(major).\(minor).\(patch)"
    }

    public static func < (lhs: AppUpdateVersion, rhs: AppUpdateVersion) -> Bool {
        if lhs.major != rhs.major {
            return lhs.major < rhs.major
        }
        if lhs.minor != rhs.minor {
            return lhs.minor < rhs.minor
        }
        return lhs.patch < rhs.patch
    }
}

private extension String {
    func dropFirstIfVersionPrefix() -> Substring {
        let value = self[...]
        guard let first = value.first,
              first == "v" || first == "V" else {
            return value
        }
        return value.dropFirst()
    }
}
