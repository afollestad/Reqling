## HTTP

These instructions cover `Sources/ReqlingKit/HTTP/`: building, sending, and importing HTTP requests.

- **`HTTPMethod.bodyPolicy` is the only gate on bodies.** The editor and `HTTPRequestBuilder` consult it, and any new caller must too. A body the policy hides stays on disk, so switching back restores it.
- **`HTTPRequestSpec.url` never carries a query string.** `queryParameters` is the source of truth, disabled rows included; pass anything external (paste, cURL, agents) through `normalized()` first.
- **One `HTTPExecutor` per project.** Its ephemeral sessions (one per TLS policy) share one cookie jar, so cookies never cross projects; keep them uncached, since an API client must always reach the server.
- Every `PreparedHTTPRequest` carries a masked `summary`; show and store that, never the raw `URLRequest`, wherever a person or agent can see it.
