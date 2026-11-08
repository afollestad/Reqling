# gRPC

Switch a request to gRPC from the protocol menu in its header.

## Calls

- **Target.** `host:port`, or `unix:/path` for a socket, plus a service and a method.
- **Messages** are proto3 JSON, with `{{variables}}` anywhere in them. **Example** fills a message with every field of its type.
- **Call types.** Unary, server-streaming, client-streaming, and bidirectional. A streaming call stays open so you can send more messages and end the stream yourself.
- **TLS.** Calls use the project's client certificates and CA certificates, the same as HTTP requests ([TLS](tls.md)).
- **No proxy.** Calls connect directly rather than through a system proxy.

## Responses

- **Timeline.** Every message, as a collapsible tree or as text, following the newest while you're scrolled to the end.
- **Metadata.** The initial metadata, trailers, and final status.
- **Unknown fields.** A received message notes any fields the schema doesn't define, which usually means your protos are older than the server's.
- **Scripts.** A [stream script](scripts.md#stream-scripts) handles each message received. While a streaming call's request stream is open, it can send more with `rq.send`.

## Schema source

- **Project protos.** In **Project Settings**, add the folders your `.proto` files live in, and optionally which files to compile.
  - Folders inside the project's own folder or repository are stored relative to it, so the project works for everyone who clones it; anything else is remembered on this Mac only.
  - Reqling compiles them with `protoc` and recompiles when they change. If `protoc` isn't installed, Reqling offers to install it, or uses one from Homebrew or your `PATH`.
- **Descriptor sets** (`.protoset`, `.binpb`), which need no `protoc`.
- **Server reflection**, for servers that expose it.
