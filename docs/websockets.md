# WebSockets

Switch a request to WebSocket from the protocol menu in its header, and **Connect** (⌘Return) to a `ws://` or `wss://` URL; `http(s)://` URLs work too.

## Handshake

- **Like an HTTP request**, with its query, headers, auth (inherited from folders, API keys in the query included), and `{{variables}}`.
- **Cookies and certificates.** It uses the project's cookies, so a session from an earlier login carries over, and its client certificates and CAs.
- **Options** holds subprotocols, the handshake's timeout, and Verify TLS.
- **`Origin`** is an automatic header you can turn on in **Headers** when a server checks it.

## Messages

- **Saved messages.** A request keeps a list of messages, text or binary (written as base64), with `{{variables}}` in either.
- **On connect.** Checked messages go out in order as soon as the connection opens, which replays a conversation.
- **While connected**, each has a **Send** button, beside a composer for messages you don't want to keep; **Save** adds one to the list. Messages sent while connected resolve against the environment you connected with.
- **Ping** measures a round trip. A keepalive in **Options** pings after a quiet stretch, ending the connection when a ping goes unanswered. Changing it applies to an open connection at once.
- **Scripts.** A [stream script](scripts.md#stream-scripts) handles each message received, and can answer with `rq.send`. Messages you send while connected also resolve what its handlers set.

## Responses

- **Timeline.** Every message both ways, as a tree or text, with the server's pings and pongs, and the close frames with their codes and reasons.
- **Handshake answer.** The server's response to the handshake; a refusal keeps its body, which usually says why.
- **Disconnect** (⌘.) closes with 1000 Normal Closure.
- **Failures.** A run counts as failed when the handshake is refused, the connection drops, or it closes with an abnormal code.

## Limits

- **Strict protocol.** A server that breaks the protocol is held to it, as a browser would hold it.
- **No compression.** `permessage-deflate` isn't offered.
- **No proxy.** Connections go directly rather than through a system proxy.
