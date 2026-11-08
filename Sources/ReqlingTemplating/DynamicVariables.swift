import Foundation

/// Built-in generated values. Each occurrence generates afresh, so two `{{$uuid}}` in one request differ.
///
/// Beyond Reqling's own four, the built-ins are Postman's, made the way Postman makes them, so requests and scripts
/// brought from Postman send what they did there. The fake data comes from Reqling's own word lists
/// (`DynamicVariables+FakeData.swift`), so it reads like Postman's without matching it word for word.
public struct DynamicVariables: Sendable {
    /// Every built-in, in the order completion offers them: Reqling's own first, then Postman's.
    public static let names = generators.map(\.name)
    /// Postman's other names for a built-in, resolved like it. Never offered: completion keeps to one name each.
    public static let aliases = ["$guid": "$uuid", "$randomUUID": "$uuid"]

    /// Whether `name` generates a value, as a built-in or an alias of one.
    public static func isKnown(_ name: String) -> Bool {
        generatorsByName[name] != nil || aliases[name] != nil
    }

    public var now: @Sendable () -> Date
    public var uuid: @Sendable () -> UUID
    /// `$randomInt`'s value, from 0 through 1,000 as Postman's.
    public var randomInt: @Sendable () -> Int
    /// A random integer in the range, for every other random built-in; tests pass a fixed sequence.
    public var random: @Sendable (Range<Int>) -> Int
    /// The zone the `$randomDate…` built-ins write their dates in, as JavaScript's `Date.toString()` does.
    public var timeZone: TimeZone

    public init(
        now: @escaping @Sendable () -> Date,
        uuid: @escaping @Sendable () -> UUID,
        randomInt: @escaping @Sendable () -> Int,
        random: @escaping @Sendable (Range<Int>) -> Int = { Int.random(in: $0) },
        // Autoupdating, so `live` follows a change of the Mac's zone while Reqling runs.
        timeZone: TimeZone = .autoupdatingCurrent
    ) {
        self.now = now
        self.uuid = uuid
        self.randomInt = randomInt
        self.random = random
        self.timeZone = timeZone
    }

    public static let live = DynamicVariables(
        now: { Date() },
        uuid: { UUID() },
        randomInt: { Int.random(in: 0...1000) }
    )

    public func value(for name: String) -> String? {
        Self.generatorsByName[Self.aliases[name] ?? name]?(self)
    }

    /// One built-in: its name and how it makes a value.
    struct Generator: Sendable {
        let name: String
        let make: @Sendable (DynamicVariables) -> String

        init(_ name: String, _ make: @escaping @Sendable (DynamicVariables) -> String) {
            self.name = name
            self.make = make
        }
    }

    /// One table for both what's offered and what's generated, so the two never drift apart.
    private static let generators = reqlingGenerators + postmanGenerators + fakeDataGenerators

    private static let reqlingGenerators: [Generator] = [
        Generator("$uuid") { $0.uuid().uuidString.lowercased() },
        Generator("$timestamp") { String(Int($0.now().timeIntervalSince1970)) },
        // Milliseconds included, as Postman's `$isoTimestamp` has them.
        Generator("$isoTimestamp") { $0.now().formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)) },
        Generator("$randomInt") { String($0.randomInt()) }
    ]

    private static let generatorsByName = Dictionary(uniqueKeysWithValues: generators.map { ($0.name, $0.make) })
}
