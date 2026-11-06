# MCP server

Reqling can run a local [MCP](https://modelcontextprotocol.io) server so AI agents on your Mac can work with your projects. Their changes appear in the window as they happen.

## What agents can do

- Create and edit projects, environments, variables, and saved requests.
- Compile protos.
- Read a GraphQL request's schema and check queries against it.
- Send requests and read their responses. An event stream or WebSocket runs for a bounded time or number of events or received messages, and a WebSocket sends its own on-connect messages or the agent's.
- Look back through each request's run history.

## Setup

Turn it on in **Settings ▸ MCP**, which also shows the setup command for Claude Code and the config for Codex:

```sh
claude mcp add --transport http reqling http://127.0.0.1:39717/mcp --header "Authorization: Bearer <token>"
```

## Security

- **Local only.** The server listens on `127.0.0.1` and requires its bearer token, which is kept in your Keychain and can be regenerated.
- **Secrets are write-only.** No tool returns one, and resolved requests and responses show them masked, even where a server echoes one back.
- **Deletions** go to the Trash.
