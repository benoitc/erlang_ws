# Features

## Scope

`erlang_ws` provides the WebSocket protocol engine — frame codec,
handshake helpers, session state machine, and client connect path.
Embedders supply the HTTP layer (RFC 6455 over HTTP/1.1, RFC 8441
over HTTP/2, RFC 9220 over HTTP/3) and a transport callback that
drives the underlying socket or stream.

## RFC coverage

- **RFC 6455** — full frame codec (all opcodes, masking,
  fragmentation), handshake helpers, close-code validation (§7.4),
  streaming UTF-8 validation across fragment boundaries.
- **RFC 7692** — permessage-deflate client / server negotiation and
  inflate / deflate (opt-in via `ws_deflate`).
- **RFC 8441** — extended CONNECT request and response validation
  for HTTP/2 (`ws_h2_upgrade`). Embedders must configure their H2
  stack to advertise `SETTINGS_ENABLE_CONNECT_PROTOCOL = 1`.
- **RFC 9220** — extended CONNECT for HTTP/3 with
  `SETTINGS_ENABLE_CONNECT_PROTOCOL` enabled in H3 settings
  (`ws_h3_upgrade`).

## Hardening

- **Masking.** Server rejects unmasked client frames; client rejects
  masked server frames. Masking uses 32-bit XOR with a random key
  per outbound client frame, generated via `crypto:strong_rand_bytes/1`.
- **Protocol invariants.** RSV bits must be zero unless an extension
  negotiated them. Opcodes 3–7 and 11–15 are reserved and rejected.
  Non-minimal length encoding is rejected. Control frames must be
  ≤ 125 bytes and cannot be fragmented.
- **Fragmentation.** Continuation frames are only accepted inside an
  open fragmented message. Opening a new data frame on top of an
  open fragment is a protocol error.
- **UTF-8.** Text frames and close-frame reason bytes are validated
  with an inlined Hoehrmann DFA. The state is carried across
  fragments so a codepoint split across frame boundaries validates
  exactly once, without allocating.
- **Close codes.** Only RFC-legal codes are allowed on the wire
  (`ws_close:valid_on_wire/1`). Reserved codes 1004 / 1005 / 1006 /
  1015 are rejected.
- **Size guards.** `max_frame` and `max_message` on the parser abort
  with close code 1009 (message too big). Defaults: 16 MiB per frame,
  64 MiB per message. Tune via `parser_opts`.
- **Auto-pong.** Pings are answered before the handler is invoked
  so slow handlers can't delay keepalive.
- **Orderly close.** Receiving a close frame echoes one back exactly
  once; the session then waits for the transport to close.
- **Ownership handshake.** The session defers its first read
  (`{active, once}`) until the embedder calls
  `ws_session:activate/1` — this closes the socket-ownership race
  that bites hand-rolled WebSocket servers.

## Out of scope (by design)

- No built-in HTTP server; the embedder validates the request line
  and hands the stream to `ws:accept/5`. Use `ws_h1_tcp_server` as a
  reference acceptor if you only need the WebSocket part.
- No authentication, cookie handling, origin-list enforcement, or
  rate limiting. Those belong in the embedder.
- No reconnect / backoff / heartbeat helpers on the client. If you
  want them, wrap `ws_client:connect/2`.
- permessage-deflate is implemented but not yet wired into the
  session automatically — call the codec from your handler if you
  need it.

## Module map

| Module | Role |
|-|-|
| `ws` | Public API: `accept/5,6`, `connect/2`, `send/2`, `close/3`. |
| `ws_frame` | RFC 6455 encode / decode, masking, UTF-8 validation. |
| `ws_close` | Close-code classification and validation. |
| `ws_h1_upgrade` | HTTP/1.1 Upgrade request parsing, 101 response build, client key gen. |
| `ws_h2_upgrade` | RFC 8441 extended CONNECT helpers (server + client). |
| `ws_h3_upgrade` | RFC 9220 extended CONNECT helpers (delegate to H2 shape). |
| `ws_handler` | Behaviour for application code. |
| `ws_transport` | Behaviour for stream I/O. |
| `ws_transport_gen_tcp` | Reference `gen_tcp` transport. |
| `ws_transport_ssl` | Reference `ssl` transport. |
| `ws_session` | `gen_statem` driving a single WebSocket connection. |
| `ws_client` | Client connect path (`ws://`, `wss://`). |
| `ws_h1_tcp_server` | Reference HTTP/1.1 acceptor + upgrade driver. |
| `ws_deflate` | RFC 7692 permessage-deflate. |
