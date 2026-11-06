import Foundation

/// Built-in generated values. Each occurrence generates afresh, so two `{{$uuid}}` in one request differ.
public struct DynamicVariables: Sendable {
    public static let names = ["$uuid", "$timestamp", "$isoTimestamp", "$randomInt"]

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
        switch name {
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
