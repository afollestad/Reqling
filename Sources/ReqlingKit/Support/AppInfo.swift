import Foundation

/// The running app's identity, read from bundle metadata at runtime. `Resources/Info.plist` is the
/// build-time source of these values, so nothing else should restate the version or bundle ID.
public struct AppInfo: Equatable, Sendable {
    public let name: String
    public let bundleIdentifier: String
    public let version: String
    public let build: String

    public init(name: String, bundleIdentifier: String, version: String, build: String) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.build = build
    }

    /// Debug builds rewrite `CFBundleDisplayName` to "Reqling Dev", so the display name wins over
    /// `CFBundleName` wherever the app names itself.
    public init(infoDictionary: [String: Any]) {
        self.init(
            name: infoDictionary["CFBundleDisplayName"] as? String
                ?? infoDictionary["CFBundleName"] as? String
                ?? "Reqling",
            bundleIdentifier: infoDictionary["CFBundleIdentifier"] as? String ?? "com.afollestad.reqling",
            version: infoDictionary["CFBundleShortVersionString"] as? String ?? "0.0.0",
            build: infoDictionary["CFBundleVersion"] as? String ?? "0"
        )
    }

    public static var current: AppInfo {
        AppInfo(infoDictionary: Bundle.main.infoDictionary ?? [:])
    }

    /// Sent by default on HTTP requests; a user-supplied `User-Agent` header overrides it.
    public var userAgent: String {
        "Reqling/\(version)"
    }
}
