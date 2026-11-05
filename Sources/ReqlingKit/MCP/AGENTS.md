## MCP Server

These instructions cover `Sources/ReqlingKit/MCP/`: the built-in MCP server (`Server/`), the tool plumbing (`Tools/`), and the tool sets (`Features/`). The app's side is `Sources/Reqling/ViewModels/AppModel+MCP.swift` and Settings ▸ MCP.

### Composition

- **Add a tool set to `MCPToolCatalog.tools`,** and build each tool as an `MCPTool`, which keeps its definition and handler together so a listed tool can never lack one. Names are unique across sets; the dispatcher traps on a repeat and `MCPToolCatalogTests` checks the shape of every tool.
- **Keep titles and descriptions short.** Clients put the whole catalog in the model's context on every turn; say what a tool does, what it refuses, and which sibling to use instead.
- **Never add a tool that manages the server itself.** Agents can't change its settings or read or rotate its token; only the person at the Mac does, in Settings.

### Handler Contract

- **Read arguments through `MCPArguments`,** whatever the advertised schema promises; it refuses unknown keys and checks every type, with a path the agent can act on.
- **Change projects through `MCPToolContext.mutate` and `ProjectLifecycle`, and Global through `MCPToolContext.mutateGlobalEnvironment`,** the paths the window uses, so secrets, the Trash, local paths, and the window's live update all stay right. Never write project files here.
- **Never return a secret value.** Describe variables with `MCPDescriptions.variable`, and mask anything a run or a server produced with `RequestRunner.maskingSecrets(in:variableOverrides:)`, since servers echo credentials back.
- **Read and write specs, auth, and certificate entries in their on-disk JSON,** so what `get_request` returns is exactly what `create_request` and `update_request` take. Row IDs follow `Sources/ReqlingKit/Storage/AGENTS.md`.
- **Reach the window only through `MCPAppHost`.** It is `nil` in tests and before launch, so a tool that needs it says so instead of failing silently.
- Mark deletions `destructive: false` and apply them without a confirmation round trip: they move files to the Trash. Clearing run history deletes for good, so it is `.destroy`.

### Transport

- **Listen on IPv4 loopback only, and check `Host`, `Origin`, and the bearer token in `MCPHTTPListener` before the SDK sees a request;** the transport's own validators repeat the checks.
