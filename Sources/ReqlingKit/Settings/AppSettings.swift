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

    public var theme: AppTheme = .system
    public var requestTimeoutSeconds: Double = 30 {
        didSet { requestTimeoutSeconds = Self.clamp(requestTimeoutSeconds) }
    }
    public var followRedirects = true
    public var verifyTLS = true

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
    }

    private enum CodingKeys: String, CodingKey {
        case theme
        case requestTimeoutSeconds
        case followRedirects
        case verifyTLS
    }

    private static func clamp(_ value: Double) -> Double {
        value.isFinite ? min(max(value, timeoutRange.lowerBound), timeoutRange.upperBound) : 30
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
