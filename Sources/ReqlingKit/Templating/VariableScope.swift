import Foundation

/// The variables visible to one run: Default's enabled variables, overridden by the active environment's, overridden
/// by one-run overrides (from MCP's `execute_request`, for example).
public struct VariableScope: Sendable {
    public struct Entry: Hashable, Sendable {
        public let value: String
        public let source: Source
        public let isSecret: Bool

        public init(value: String, source: Source, isSecret: Bool) {
            self.value = value
            self.source = source
            self.isSecret = isSecret
        }
    }

    public enum Source: Hashable, Sendable {
        case environment(id: EnvironmentID, name: String)
        case override
    }

    public private(set) var entries: [String: Entry]

    public init(entries: [String: Entry] = [:]) {
        self.entries = entries
    }

    /// `activeEnvironmentID` of `nil` or of the Default environment means Default alone.
    public init(document: ProjectDocument, activeEnvironmentID: EnvironmentID?, overrides: [String: String] = [:]) {
        var entries: [String: Entry] = [:]
        func add(_ environment: RequestEnvironment) {
            for variable in environment.variables where variable.isEnabled && !variable.key.isEmpty {
                entries[variable.key] = Entry(
                    value: variable.value,
                    source: .environment(id: environment.id, name: environment.name),
                    isSecret: variable.isSecret
                )
            }
        }
        add(document.defaultEnvironment)
        if let activeEnvironmentID, !document.isDefaultEnvironment(activeEnvironmentID),
           let active = document.environment(activeEnvironmentID) {
            add(active)
        }
        for (key, value) in overrides {
            entries[key] = Entry(value: value, source: .override, isSecret: false)
        }
        self.entries = entries
    }

    public func lookup(_ name: String) -> Entry? {
        entries[name]
    }

    /// All visible names, sorted, for completion.
    public var names: [String] {
        entries.keys.sorted()
    }
}

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
