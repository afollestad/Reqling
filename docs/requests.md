# Requests

HTTP requests, their responses, event streams, and run history. [GraphQL](graphql.md), [gRPC](grpc.md), and [WebSockets](websockets.md) have their own pages.

## Building a request

- **Protocol.** Switch any request between HTTP, gRPC, and WebSocket from the protocol menu in its header; its auth, headers, and host carry over.
- **Methods.** Any, including custom ones such as `PURGE`. Methods that never carry a body (`GET`, `HEAD`, `TRACE`) keep the body you typed and send it again if you switch back.
- **Bodies.** Raw with any Content-Type, form-data, x-www-form-urlencoded, binary, and GraphQL (a query and its variables, sent as the JSON body GraphQL servers expect).
- **Auth.** Basic, Bearer, and API key (header or query), set per request or inherited from a folder or the project.
- **Auto-indent.** JSON and JavaScript editors and the GraphQL query editor indent as you press Return:
  - A new line keeps the indentation above, one level deeper after `{` or `[`.
  - A bracket left open gets its closer on the next line, with the cursor between.
  - A `}` or `]` typed at the start of a line moves back to its opener's indentation.
- **Unticked rows.** Untick a parameter, header, form field, or variable to keep it but leave it out. Shift-click a checkbox to set every row between it and the last one you clicked, or use **Select All** and **Select None** above the rows.
- **Automatic headers** are listed alongside yours, including the ones macOS adds (`Host`, `Accept-Encoding`, `Accept-Language`).
  - Add a header with the same name to replace one.
  - Switching off `User-Agent`, `Accept`, or `Content-Type` stops Reqling setting it, and macOS then sends its own default.
- **cURL.** Paste a cURL command into the URL field to import it. **Copy as cURL** (⌥⌘C) exports the resolved request.

## Responses

- **Status, timing per phase, headers, and the body.**
- **Trees.** JSON and XML open as collapsible trees, with any value, key, or path a right-click away.
- **Pretty** re-indents JSON without reordering keys. **Raw** shows the body as sent.
- **Any size.** Bodies stay highlighted and scroll smoothly, and images preview.

## Event streams

- **Live.** A `text/event-stream` (Server-Sent Events) response stays open and shows events as they arrive, each with its type, ID, data, and arrival time, as a tree whose JSON data opens to its fields, or as text.
- **GET streams reconnect** whenever they end, after the server's `retry:` delay, sending `Last-Event-ID`.
- **Other methods**, such as a POST to an LLM API, end when the server closes the stream rather than running again.
- **Stop** (⌘.) ends a stream and keeps its events.
- **Timeout** is how long a stream may stay silent.

## Find

- **⌘F** finds within the focused body editor, and searches a response's text or tree in place.
- **Timelines** of messages or events are searchable in their Tree mode.

## Run history

- **Every run is kept.** Open it with **Request ▸ Show Run History** (⌘Y) or the toolbar's inspector button.
- **Pick a run** to see its response again, re-run it, or restore its request into the editor.
- **Compare** two selected runs line by line, with JSON re-indented first so only real changes show.
- **Open connections.** An event stream, gRPC call, or WebSocket still open when Reqling quits is saved as it stands.
- **On this Mac.** History never goes in the project. **Settings ▸ History** sets how long and how much is kept, and **Clear Run History…** in the sidebar's menus clears a request's or a project's.
