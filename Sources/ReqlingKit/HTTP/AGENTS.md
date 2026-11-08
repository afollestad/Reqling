## HTTP

These instructions cover `Sources/ReqlingKit/HTTP/`: building, sending, and importing HTTP requests.

- **`HTTPMethod.bodyPolicy` is the only gate on bodies.** The editor and `HTTPRequestBuilder` consult it, and any new caller must too. A body the policy hides stays on disk, so switching back restores it.
- **A `URLAddressed` spec's `url` (HTTP's and WebSocket's) never carries a query string.** `queryParameters` is the source of truth, disabled rows included; pass anything external (paste, cURL, agents) through `normalized()` first.
- **One `HTTPExecutor` per project.** Its ephemeral sessions (one per TLS policy) share one cookie jar, which WebSocket handshakes read and fill through `HTTPExecutor.cookies`, so cookies never cross projects; keep them uncached, since an API client must always reach the server.
- **Change a project's jar outside a transport only through `RequestRunner.cookieJar(for:creating:)`.** It returns `nil` once the library drops the project, so a script's or agent's change landing after `forget` never brings its executor back.
- **Detect event streams only from a 200 response's `Content-Type`, in `HTTPExecutor`.** Requests never declare one, so the editor, MCP, and re-runs stream alike.
- Every `PreparedHTTPRequest` carries a masked `summary`; show and store that, never the raw `URLRequest`, wherever a person or agent can see it.
