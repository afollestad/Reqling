/// The one MCP server Reqling exposes, composed from per-area tool sets in the order clients list them.
@MainActor
public enum MCPToolCatalog {
    /// The server name clients register; the single place it is spelled.
    public static let serverName = "reqling"

    static let instructions = """
    These tools operate Reqling, the macOS API client running on this Mac: its projects, their environments and \
    {{variables}}, the saved request templates in them (HTTP and gRPC), and sending those requests. Changes show up \
    in Reqling's window as they happen and are saved to the project's files, so prefer these tools over editing \
    project files directly. Saved requests are templates: their {{variables}} resolve only when a request runs, \
    against the environment chosen for that run. Secret values are write-only: no tool returns one, and responses \
    and resolved requests show them masked. Deleting moves files to the Trash, where Finder can put them back.
    """

    /// Every tool. `MCPToolDispatcher` traps when two share a name.
    static func tools(_ context: MCPToolContext) -> [MCPTool] {
        MCPProjectTools(context: context).tools
            + MCPEnvironmentTools(context: context).tools
            + MCPRequestTools(context: context).tools
            + MCPExecutionTools(context: context).tools
            + MCPGRPCTools(context: context).tools
            + MCPTLSTools(context: context).tools
            + MCPAppTools(context: context).tools
    }
}
