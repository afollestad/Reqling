# MCP server

Reqling can run a local [MCP](https://modelcontextprotocol.io) server so AI agents on your Mac can work with your projects. Their changes appear in the window as they happen.

## What agents can do

- Create and edit projects, environments, variables, and saved requests, and reset or save the current values scripts set.
- Write pre-request, stream, and post-response scripts, with the [API reference](scripts.md#api-reference) and the problems in what they wrote.
- Compile protos.
- Read a GraphQL request's schema and check queries against it.
- Send requests and read their responses, with their scripts' test results, console, and the variables and cookies they changed, and what stream scripts handled; one a pre-request script skips comes back not sent. An event stream or WebSocket runs for a bounded time or number of events or received messages, and a WebSocket sends its own on-connect messages or the agent's.
- Run a folder's or the project's requests in order, a number of times or once per row of data, with the same badges and bar in the sidebar as your own runs, which you can stop ([Running folders and projects](running-folders.md)). One runs at a time, yours or an agent's; an agent's stops after 9.5 minutes and returns what finished.
- Look back through each request's run history.
- See, set, and delete each project's cookies ([Cookies](scripts.md#cookies)).

## Setup

Turn it on in **Settings ▸ MCP**, which also shows the setup command for Claude Code and the config for Codex:

```sh
claude mcp add --transport http reqling http://127.0.0.1:39717/mcp --header "Authorization: Bearer <token>"
```

## Security

- **Local only.** The server listens on `127.0.0.1` and requires its bearer token, which is kept in your Keychain and can be regenerated.
- **Secrets are write-only.** No tool returns one, and resolved requests and responses show them masked, even where a server echoes one back. Values a script makes secret are masked too, in past runs as well. After Reqling relaunches, a past run whose scripts made a value secret for that run alone has its response left out, since nothing holds that value any more.
- **Scripts run only in projects you trust.** An agent can't trust a project for you; in one you haven't trusted, its requests go out without their scripts, and the agent is told why.
- **Cookie values stay out of `list_cookies`.** An agent sees each cookie's name, domain, path, expiry, and flags. Values still reach agents in the `Set-Cookie` headers of responses, and in whatever a script an agent runs prints.
- **Deletions** go to the Trash, on every Mac a project [syncs](projects.md#syncing-with-icloud) to, except clearing run history and deleting cookies, which can't be undone.
