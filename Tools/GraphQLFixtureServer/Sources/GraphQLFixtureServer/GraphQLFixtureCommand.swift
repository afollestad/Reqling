import Dispatch
import Foundation

/// The `graphql-fixture-server` command line, kept in the library so its parsing is tested with the server.
public enum GraphQLFixtureCommand {
    public struct Arguments: Equatable, Sendable {
        public var port = 4000
        public var token: String?
        public var introspection = true
        public var schemaPath: String?

        public init(port: Int = 4000, token: String? = nil, introspection: Bool = true, schemaPath: String? = nil) {
            self.port = port
            self.token = token
            self.introspection = introspection
            self.schemaPath = schemaPath
        }
    }

    public struct UsageError: Error, Equatable, CustomStringConvertible {
        public let description: String
    }

    public static let usage = """
        usage: graphql-fixture-server [--port <port>] [--token <token>] [--no-introspection] [--schema <file.graphql>]

          --port <port>         Listen on 127.0.0.1:<port> (default 4000; 0 picks a free port).
          --token <token>       Require "Authorization: Bearer <token>".
          --no-introspection    Refuse introspection queries, as production servers often do.
          --schema <file>       Serve this SDL file instead of the built-in library schema.
        """

    public static func parse(_ arguments: [String]) throws(UsageError) -> Arguments {
        var parsed = Arguments()
        var remaining = arguments[...]
        func value(for flag: String) throws(UsageError) -> String {
            guard let value = remaining.popFirst(), !value.hasPrefix("--") else {
                throw UsageError(description: "\(flag) needs a value.")
            }
            return value
        }
        while let argument = remaining.popFirst() {
            switch argument {
            case "--port":
                let text = try value(for: argument)
                guard let port = Int(text), (0...65_535).contains(port) else {
                    throw UsageError(description: "\(text) is not a port.")
                }
                parsed.port = port
            case "--token":
                parsed.token = try value(for: argument)
            case "--no-introspection":
                parsed.introspection = false
            case "--schema":
                parsed.schemaPath = try value(for: argument)
            default:
                throw UsageError(description: "Unknown option \(argument).")
            }
        }
        return parsed
    }

    /// Runs the server until SIGINT or SIGTERM, printing each request; returns the process's exit status.
    public static func main(_ arguments: [String]) async -> Int32 {
        // Line-buffered even when redirected to a file, so a log shows each request as it arrives.
        setvbuf(stdout, nil, _IOLBF, 0)
        if arguments.contains("--help") || arguments.contains("-h") {
            print(usage)
            return 0
        }
        let parsed: Arguments
        do {
            parsed = try parse(arguments)
        } catch {
            printError("\(error.description)\n\n\(usage)")
            return 64
        }
        var options = GraphQLFixtureServer.Options(
            port: parsed.port,
            requiredBearerToken: parsed.token,
            introspection: parsed.introspection ? .enabled : .disabled(status: 200)
        )
        if let path = parsed.schemaPath {
            do {
                options.sdl = try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
            } catch {
                printError("Could not read \(path): \(error.localizedDescription)")
                return 66
            }
        }
        let server: GraphQLFixtureServer
        do {
            server = try await GraphQLFixtureServer.start(options)
        } catch {
            printError("Could not start: \(error)")
            return 1
        }
        print("Serving GraphQL at \(server.url)")
        if let token = parsed.token {
            print("Requests need \"Authorization: Bearer \(token)\".")
        }
        if !parsed.introspection {
            print("Introspection is refused.")
        }
        print("Press Control-C to stop.")
        let logging = Task {
            for await request in server.received {
                print("\(request.method) \(request.uri) \(operationName(of: request) ?? "")")
            }
        }
        await untilInterrupted()
        logging.cancel()
        try? await server.shutdown()
        return 0
    }

    private static func operationName(of request: GraphQLFixtureServer.RecordedRequest) -> String? {
        let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any]
        return object?["operationName"] as? String
    }

    private static func untilInterrupted() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumed = ResumeOnce(continuation)
            for signalNumber in [SIGINT, SIGTERM] {
                signal(signalNumber, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
                source.setEventHandler { resumed.resume() }
                source.resume()
                resumed.retain(source)
            }
        }
    }

    private static func printError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

/// Resumes a continuation the first time either signal arrives, and keeps the signal sources alive until then.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var sources: [any DispatchSourceSignal] = []

    init(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    func retain(_ source: any DispatchSourceSignal) {
        lock.withLock { sources.append(source) }
    }

    func resume() {
        let continuation = lock.withLock {
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume()
    }
}
