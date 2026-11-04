import Foundation
import MCP
import Synchronization

/// Routes a tool call to its handler, bounding how long it may run and how much it may return, and turning a thrown
/// error into an error result the agent can read.
@MainActor
public final class MCPToolDispatcher {
    /// Above this the output is replaced by an error, since clients choke on (or silently cut) huge results; tools that
    /// return bodies truncate them well below it.
    static let outputLimit = 1_000_000

    public let tools: [MCPTool]
    private let toolsByName: [String: MCPTool]
    private let sleep: @Sendable (Duration) async throws -> Void
    private let beforeCall: @MainActor () -> Void

    /// Traps on a duplicate name: two features claiming one name is a programming error a test catches.
    init(
        tools: [MCPTool],
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        beforeCall: @escaping @MainActor () -> Void = {}
    ) {
        var byName: [String: MCPTool] = [:]
        for tool in tools {
            precondition(byName.updateValue(tool, forKey: tool.name) == nil, "Duplicate MCP tool name: \(tool.name)")
        }
        self.tools = tools
        toolsByName = byName
        self.sleep = sleep
        self.beforeCall = beforeCall
    }

    /// Every catalog tool over `context`, saving the window's pending edits before each call. That has to happen
    /// before a tool reads anything: one that read first would build its change on a copy missing the user's latest
    /// typing, then write that copy over it.
    public convenience init(context: MCPToolContext, sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.init(tools: MCPToolCatalog.tools(context), sleep: sleep) { [weak context] in
            context?.host?.flushPendingEdits()
        }
        context.dispatcher = self
    }

    public var definitions: [Tool] {
        tools.map(\.definition)
    }

    /// Runs the tool, ending it with an error result when it outlives its `timeout`; the handler is cancelled then, and
    /// handlers cooperate (a run in flight is cancelled with it).
    public func call(_ name: String, arguments: [String: Value]?) async -> MCPToolResult {
        guard let tool = toolsByName[name] else {
            return .failure("Reqling has no tool named \(name).")
        }
        beforeCall()
        let handler = tool.handler
        let arguments = MCPArguments(arguments ?? [:])
        let timeout = tool.timeout
        let sleep = self.sleep
        let timedOut = Mutex(false)
        let work = Task { @MainActor in
            await Self.run(handler, arguments)
        }
        let timer = Task {
            do {
                try await sleep(timeout)
            } catch {
                return
            }
            timedOut.withLock { $0 = true }
            work.cancel()
        }
        let result = await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
        timer.cancel()
        if timedOut.withLock({ $0 }) {
            return .failure("\(name) didn't finish within \(Self.seconds(timeout)) and was stopped.")
        }
        return Self.bounded(result)
    }

    private static func run(
        _ handler: @MainActor (MCPArguments) async throws -> MCPToolResult,
        _ arguments: MCPArguments
    ) async -> MCPToolResult {
        do {
            return try await handler(arguments)
        } catch let error as MCPToolError {
            return .failure(error.message)
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private static func bounded(_ result: MCPToolResult) -> MCPToolResult {
        let structured = result.structuredContent.map { MCPJSON.text($0).utf8.count } ?? 0
        guard result.text.utf8.count + structured <= outputLimit else {
            return .failure("The result was larger than Reqling returns over MCP (\(outputLimit / 1_000) KB); narrow the request.")
        }
        return result
    }

    private nonisolated static func seconds(_ duration: Duration) -> String {
        "\(duration.components.seconds) seconds"
    }
}
