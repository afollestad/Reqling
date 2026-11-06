import Foundation
import Observation

public enum AppTheme: String, Hashable, Sendable, Codable, CaseIterable {
    case system
    case light
    case dark
}

/// App-wide preferences. Decoding never fails: a missing or invalid value falls back to its default, and numbers are
/// clamped to their supported ranges, so a settings blob from another version cannot reset everything.
public struct AppSettings: Hashable, Sendable, Codable {
    public static let timeoutRange: ClosedRange<Double> = 1...600
    /// How long one phase of scripts may run before it's stopped.
    public static let scriptTimeLimitRange: ClosedRange<Double> = 1...300
    /// Unprivileged ports only, so the MCP server never needs elevated rights.
    public static let mcpPortRange: ClosedRange<Int> = 1_024...65_535
    public static let defaultMCPPort = 39_717

    public var theme: AppTheme = .system
    public var requestTimeoutSeconds: Double = 30 {
        didSet { requestTimeoutSeconds = Self.clamp(requestTimeoutSeconds) }
    }
    public var followRedirects = true
    public var verifyTLS = true
    /// A `protoc` to use instead of searching for one; blank means search. `ProtocLocator` reports a broken override
    /// rather than falling back to another protoc.
    public var protocPath: String? {
        didSet { protocPath = Self.normalizedPath(protocPath) }
    }
    /// The deadline for a gRPC call, clamped to the same range as the HTTP request timeout.
    public var grpcDeadlineSeconds: Double = 30 {
        didSet { grpcDeadlineSeconds = Self.clamp(grpcDeadlineSeconds) }
    }
    /// The built-in MCP server is off until the user turns it on.
    public var mcpEnabled = false
    public var mcpPort = AppSettings.defaultMCPPort {
        didSet { mcpPort = Self.clampPort(mcpPort) }
    }
    public var checksForUpdatesAutomatically = true
    public var historyRetention: HistoryRetention = .month
    public var historySizeLimit: HistorySizeLimit = .megabytes500
    /// How long each phase of a request's scripts may run, all its levels together.
    public var scriptTimeLimitSeconds: Double = 10 {
        didSet { scriptTimeLimitSeconds = Self.clampScriptTimeLimit(scriptTimeLimitSeconds) }
    }

    public init() {}

    public var requestDefaults: HTTPRequestDefaults {
        HTTPRequestDefaults(timeoutSeconds: requestTimeoutSeconds, followRedirects: followRedirects, verifyTLS: verifyTLS)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()
        theme = (try? container.decodeIfPresent(AppTheme.self, forKey: .theme)) ?? defaults.theme
        let timeout = try? container.decodeIfPresent(Double.self, forKey: .requestTimeoutSeconds)
        requestTimeoutSeconds = Self.clamp(timeout ?? defaults.requestTimeoutSeconds)
        followRedirects = (try? container.decodeIfPresent(Bool.self, forKey: .followRedirects)) ?? defaults.followRedirects
        verifyTLS = (try? container.decodeIfPresent(Bool.self, forKey: .verifyTLS)) ?? defaults.verifyTLS
        protocPath = Self.normalizedPath((try? container.decodeIfPresent(String.self, forKey: .protocPath)) ?? nil)
        let deadline = try? container.decodeIfPresent(Double.self, forKey: .grpcDeadlineSeconds)
        grpcDeadlineSeconds = Self.clamp(deadline ?? defaults.grpcDeadlineSeconds)
        mcpEnabled = (try? container.decodeIfPresent(Bool.self, forKey: .mcpEnabled)) ?? defaults.mcpEnabled
        let port = try? container.decodeIfPresent(Int.self, forKey: .mcpPort)
        mcpPort = Self.clampPort(port ?? defaults.mcpPort)
        checksForUpdatesAutomatically = (try? container.decodeIfPresent(Bool.self, forKey: .checksForUpdatesAutomatically))
            ?? defaults.checksForUpdatesAutomatically
        historyRetention = (try? container.decodeIfPresent(HistoryRetention.self, forKey: .historyRetention)) ?? defaults.historyRetention
        historySizeLimit = (try? container.decodeIfPresent(HistorySizeLimit.self, forKey: .historySizeLimit)) ?? defaults.historySizeLimit
        let scriptTimeLimit = try? container.decodeIfPresent(Double.self, forKey: .scriptTimeLimitSeconds)
        scriptTimeLimitSeconds = Self.clampScriptTimeLimit(scriptTimeLimit ?? defaults.scriptTimeLimitSeconds)
    }

    private enum CodingKeys: String, CodingKey {
        case theme
        case requestTimeoutSeconds
        case followRedirects
        case verifyTLS
        case protocPath
        case grpcDeadlineSeconds
        case mcpEnabled
        case mcpPort
        case checksForUpdatesAutomatically
        case historyRetention
        case historySizeLimit
        case scriptTimeLimitSeconds
    }

    private static func clamp(_ value: Double) -> Double {
        value.isFinite ? min(max(value, timeoutRange.lowerBound), timeoutRange.upperBound) : 30
    }

    private static func clampScriptTimeLimit(_ value: Double) -> Double {
        value.isFinite ? min(max(value, scriptTimeLimitRange.lowerBound), scriptTimeLimitRange.upperBound) : 10
    }

    private static func clampPort(_ port: Int) -> Int {
        min(max(port, mcpPortRange.lowerBound), mcpPortRange.upperBound)
    }

    /// A text field clears to `""`, which must mean "no override", not a path to nothing.
    private static func normalizedPath(_ path: String?) -> String? {
        guard let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

/// Persists `AppSettings` as one JSON value in a defaults domain and publishes changes. Read settings only through
/// it; reading the defaults directly skips the decoding defaults and clamping.
@MainActor
@Observable
public final class SettingsStore {
    public static let defaultsKey = "settings"

    public private(set) var settings: AppSettings
    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey), let settings = try? JSONDecoder().decode(AppSettings.self, from: data) {
            self.settings = settings
        } else {
            settings = AppSettings()
        }
    }

    public func update(_ transform: (inout AppSettings) -> Void) {
        var copy = settings
        transform(&copy)
        guard copy != settings else {
            return
        }
        settings = copy
        if let data = try? JSONEncoder().encode(copy) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}
