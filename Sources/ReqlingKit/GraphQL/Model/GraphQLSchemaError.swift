import Foundation

/// Why a schema could not be read or loaded, in a sentence fit to show.
public struct GraphQLSchemaError: Error, Hashable, Sendable, LocalizedError {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? {
        message
    }
}
