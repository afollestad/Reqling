import Foundation

/// Built-in generated values. Each occurrence generates afresh, so two `{{$uuid}}` in one request differ.
public struct DynamicVariables: Sendable {
    /// The built-ins completion offers.
    public static let names = ["$uuid", "$timestamp", "$isoTimestamp", "$randomInt"]
    /// Postman's names for a built-in, resolved like it so requests and scripts brought from Postman send what they did
    /// there. Never offered: completion keeps to Reqling's own names.
    public static let aliases = ["$guid": "$uuid", "$randomUUID": "$uuid"]

    /// Whether `name` generates a value, as a built-in or an alias of one.
    public static func isKnown(_ name: String) -> Bool {
        names.contains(name) || aliases[name] != nil
    }

    public var now: @Sendable () -> Date
    public var uuid: @Sendable () -> UUID
    public var randomInt: @Sendable () -> Int

    public init(
        now: @escaping @Sendable () -> Date,
        uuid: @escaping @Sendable () -> UUID,
        randomInt: @escaping @Sendable () -> Int
    ) {
        self.now = now
        self.uuid = uuid
        self.randomInt = randomInt
    }

    public static let live = DynamicVariables(
        now: { Date() },
        uuid: { UUID() },
        randomInt: { Int.random(in: 0...1000) }
    )

    public func value(for name: String) -> String? {
        switch Self.aliases[name] ?? name {
        case "$uuid":
            return uuid().uuidString.lowercased()
        case "$timestamp":
            return String(Int(now().timeIntervalSince1970))
        case "$isoTimestamp":
            return now().formatted(.iso8601)
        case "$randomInt":
            return String(randomInt())
        default:
            return nil
        }
    }
}
