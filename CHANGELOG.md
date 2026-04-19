# Changelog

All notable changes to this project are documented here. Format loosely
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions
follow [Semantic Versioning](https://semver.org/).

## [0.1.0] — 2026-04-19

Initial release.

### Frame codec

- RFC 6455 encode / decode for all opcodes (text, binary, ping, pong,
  close, continuation).
- Masking / unmasking (32-bit XOR), symmetric and streamable.
- Fragmentation reassembly across continuation frames, with an open
  fragment state machine.
- UTF-8 validation for text payloads and close reasons via an
  inlined Hoehrmann DFA, streaming-safe across fragment boundaries.
- Close-code validation per RFC 6455 §7.4 (`ws_close`). Reserved
  codes 1004 / 1005 / 1006 / 1015 rejected on the wire; 3000–4999
  accepted for registration / application use.
- Size guards: `max_frame` and `max_message` options on the parser,
  enforced during single-frame decode and fragment accumulation.

### Handshake helpers

- `ws_h1_upgrade` — server-side validation of `Upgrade`,
  `Connection`, `Sec-WebSocket-Key`, `Sec-WebSocket-Version`;
  `Sec-WebSocket-Accept` generation; subprotocol negotiation;
  client-side key generation, request build, 101 response validation.
- `ws_h2_upgrade` — RFC 8441 extended CONNECT pseudo-header
  validation (`:method=CONNECT`, `:protocol=websocket`, `:scheme`,
  `:authority`, `:path`); server response builder; client request
  builder that refuses to issue a CONNECT when the peer has not
  advertised `SETTINGS_ENABLE_CONNECT_PROTOCOL = 1`.
- `ws_h3_upgrade` — RFC 9220 mirror of the H2 helpers.

### Session

- `ws_session` — `gen_statem` driving the session. States
  `ready_wait -> open -> closing`. Auto-responds to peer pings with
  matching pongs; surfaces ping / pong to the handler for custom
  behaviour.
- Orderly close handshake: on receiving a close frame, echoes a
  close back (only once) before exiting normally. Peer-initiated
  protocol violations trigger a close frame with the matching code
  (1002 protocol error / 1007 invalid UTF-8 / 1009 message too big)
  followed by socket shutdown.
- `ws_handler` behaviour: `init/2`, `handle_in/2`, `handle_info/2`,
  `terminate/2`. All callbacks can `reply` with outbound frames.

### Transport layer

- `ws_transport` behaviour — `send/2`, `activate/1`, `close/1`,
  `controlling_process/2`, `classify/2`, `recv/2` (optional, used by
  the client during the HTTP/1.1 handshake), `peername/1` (optional).
- `ws_transport_gen_tcp` — reference `gen_tcp` transport used by
  tests.
- `ws_transport_ssl` — OTP `ssl` transport used by `wss://` client
  connections.

### Reference server

- `ws_h1_tcp_server` — a minimal `gen_tcp` acceptor + HTTP/1.1
  upgrade driver built on top of the library helpers. Supports plain
  TCP and TLS via the `tls` option. Doubles as a runnable example
  and the server-side driver of `ws_examples_SUITE`.

### Client

- `ws_client:connect/2` for `ws://` / `wss://` URLs. Builds the
  RFC 6455 upgrade request, validates the 101 response (including
  `Sec-WebSocket-Accept` cross-check), starts a `ws_session` in
  client mode with the user handler.
- Automatic subprotocol, extension, origin, and extra-header
  handling on the request side.

### Extensions

- `ws_deflate` — RFC 7692 permessage-deflate.
  - Server-side negotiation of client offers with configurable
    takeover / window-bits policy; ignore-on-disagreement semantics.
  - Client-side offer builder and server-response parser.
  - Inflate / deflate primitives with takeover management.

### Examples

- `examples/echo_server.erl` — RFC 6455 echo server backed by
  `ws_h1_tcp_server`.
- `examples/echo_client.erl` — synchronous send-and-wait client,
  uses `ws:connect/2`.
- `examples/chat_server.erl` — broadcast chat server using `pg` for
  fan-out between sessions.

### Tests

- 142 EUnit tests across codec, close codes, handshake helpers,
  deflate.
- 4 PropEr properties: mask involution, round-trip in both
  directions, chunked-delivery preserves messages.
- 25 Common Test cases total:
  - 10 in `ws_session_SUITE` — text / binary / large-payload echo,
    ping/pong, fragmentation, orderly-close, server-initiated close,
    bad-UTF-8 rejection, oversize-frame rejection, handler info
    fan-out.
  - 3 in `ws_client_SUITE` — client↔server round-trip.
  - 12 in `ws_examples_SUITE` — end-to-end coverage of the
    `examples/` modules plus subprotocol negotiation, 20 concurrent
    clients, TLS `wss://` round-trip, 512 KiB payload, fragmented
    text delivered raw.
- Autobahn compliance suite (`WS_RUN_AUTOBAHN=1`) — 300 cases across
  sections 1–9. All OK / NON-STRICT / INFORMATIONAL; zero failures.

### Documentation

- `README.md` — quickstart with server and client examples, module
  map, embedder integration notes.
- `docs/guide.md` — tutorial (mental model, handler, server, client,
  sending frames, closing, subprotocols, TLS, limits). Every code
  snippet is mechanically verified by `ws_docs_snippets_SUITE`.
- `docs/embedding.md` — HTTP/1.1, RFC 8441 (HTTP/2), and RFC 9220
  (HTTP/3) integration patterns plus instructions for writing a
  custom `ws_transport`.
- `docs/errors.md` — every failure mode the library surfaces, with
  close codes and remediation.
- `docs/features.md` — RFC coverage, hardening list, scope
  boundaries, full module map.
- `LICENSE` — Apache-2.0.

[0.1.0]: https://github.com/benoitc/erlang_ws/releases/tag/0.1.0
