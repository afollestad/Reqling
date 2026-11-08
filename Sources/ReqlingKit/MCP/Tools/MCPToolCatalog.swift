/// The one MCP server Reqling exposes, composed from per-area tool sets in the order clients list them.
@MainActor
public enum MCPToolCatalog {
    /// The server name clients register; the single place it is spelled.
    public static let serverName = "reqling"

    static let instructions = """
    These tools operate Reqling, the macOS API client running on this Mac: its projects, their environments and \
    {{variables}}, the saved request templates in them (HTTP, gRPC, and WebSocket), and sending those requests. Changes show up \
    in Reqling's window as they happen and are saved to the project's files, so prefer these tools over editing \
    project files directly. Saved requests are templates: their {{variables}} resolve only when a request runs, \
    against the environment chosen for that run. The Global environment's variables apply to every project, beneath \
    each project's Default. Requests, folders, and projects can carry pre-request, stream, and post-response JavaScript; \
    get_script_reference describes its API. Secret values are write-only: no tool returns one, and responses and resolved requests \
    show them masked. Each project keeps its cookies in memory until Reqling quits, and list_cookies describes them \
    without their values. Deleting moves files to the Trash, where Finder can put them back; clearing run history or \
    deleting cookies can't be undone.
    """

    /// Every tool. `MCPToolDispatcher` traps when two share a name.
    static func tools(_ context: MCPToolContext) -> [MCPTool] {
        MCPProjectTools(context: context).tools
            + MCPEnvironmentTools(context: context).tools
            + MCPRequestTools(context: context).tools
            + MCPExecutionTools(context: context).tools
            + MCPBatchTools(context: context).tools
            + MCPHistoryTools(context: context).tools
            + MCPCookieTools(context: context).tools
            + MCPGRPCTools(context: context).tools
            + MCPGraphQLTools(context: context).tools
            + MCPTLSTools(context: context).tools
            + MCPAppTools(context: context).tools
    }
}
