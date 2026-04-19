# erlang_ws

[![CI](https://github.com/benoitc/erlang_ws/actions/workflows/ci.yml/badge.svg)](https://github.com/benoitc/erlang_ws/actions/workflows/ci.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/erlang_ws.svg)](https://hex.pm/packages/erlang_ws)
[![License: Apache-2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

WebSocket protocol library for Erlang. Pure-Erlang, no runtime
dependencies.

- **RFC 6455** — WebSocket over HTTP/1.1 (client + server).
- **RFC 8441** — Bootstrapping WebSockets with HTTP/2 (extended
  CONNECT) — pseudo-header validation helpers; integration lives in
  the embedder (`erlang_h2`).
- **RFC 9220** — Bootstrapping WebSockets with HTTP/3 — same helpers,
  exposed under `ws_h3_upgrade`.
- **RFC 7692** — permessage-deflate negotiation + codec.

`erlang_ws` is a protocol library, **not a server**. Embedders
(`erlang_h1`, `erlang_h2`, `erlang_quic/h3`, Livery, Cowboy, ...) own
the HTTP layer and the stream handle, call the upgrade validators,
and hand the stream over to a session via a transport callback.

The hex.pm package is `erlang_ws`; the OTP application and module
atoms are `ws`. Call sites write `ws:accept/5`, `ws:connect/2`, etc.

## Quickstart

Three runnable examples live in
[`examples/`](https://github.com/benoitc/erlang_ws/tree/main/examples):

- `echo_server.erl` — echoes every text / binary frame.
- `echo_client.erl` — synchronous send-and-wait client.
- `chat_server.erl` — broadcast chat server (`pg`-backed).

Each is ~50 lines and directly exercised by `ws_examples_SUITE`. The
examples use the bundled reference HTTP/1.1 listener,
`ws_h1_tcp_server` — a small `gen_tcp` acceptor loop that validates
the upgrade request and hands the stream to `ws:accept/5`. Embedders
with a full HTTP stack replace it with their own upgrade path.

### Echo server (excerpt from `examples/echo_server.erl`)

```erlang
-module(echo_server).
-behaviour(ws_handler).
-export([run/0, init/2, handle_in/2, handle_info/2, terminate/2]).

run() ->
    {ok, _} = application:ensure_all_started(ws),
    {ok, _} = ws_h1_tcp_server:start_link(
        #{port => 8080, handler => ?MODULE, handler_opts => #{}}).

init(_Req, State)              -> {ok, State}.
handle_in({text, D}, State)    -> {reply, {text, D}, State};
handle_in({binary, D}, State)  -> {reply, {binary, D}, State};
handle_in(_, State)            -> {ok, State}.
handle_info(_, State)          -> {ok, State}.
terminate(_, _)                -> ok.
```

Run it:

```shell
rebar3 as test compile
erl -pa _build/test/lib/ws/ebin _build/test/lib/ws/examples \
    -s echo_server run -noshell
```

### Client (excerpt from `examples/echo_client.erl`)

```erlang
send(Url, Msg) ->
    {ok, _} = application:ensure_all_started(ws),
    {ok, Conn} = ws:connect(Url,
        #{handler      => ?MODULE,
          handler_opts => #{notify => self()}}),
    ok = ws:send(Conn, {text, Msg}),
    receive {echo, Bin} -> ws:close(Conn, 1000, <<>>), {ok, Bin}
    after 5000         -> {error, timeout}
    end.
```

Usage:

```erlang
1> echo_client:send(<<"ws://127.0.0.1:8080/">>, <<"hello">>).
{ok, <<"hello">>}
```

## Module map

| Module | Role |
|-|-|
| `ws` | Public API: `accept/5`, `connect/2`, `send/2`, `close/3`. |
| `ws_frame` | RFC 6455 encode / decode, masking, UTF-8 validation. |
| `ws_close` | Close-code classification and validation. |
| `ws_h1_upgrade` | HTTP/1.1 Upgrade request parsing, 101 response build, client key gen. |
| `ws_h2_upgrade` | RFC 8441 extended CONNECT helpers (server + client). |
| `ws_h3_upgrade` | RFC 9220 extended CONNECT helpers (delegate to H2 shape). |
| `ws_handler` | Behaviour for application code. |
| `ws_transport` | Behaviour for stream I/O. |
| `ws_transport_gen_tcp` / `ws_transport_ssl` | Reference transports. |
| `ws_session` | `gen_statem` driving a single WebSocket connection. |
| `ws_client` | Client connect path (`ws://`, `wss://`). |
| `ws_h1_tcp_server` | Reference HTTP/1.1 acceptor + upgrade driver. |
| `ws_deflate` | RFC 7692 permessage-deflate. |

## Tests

- **Unit (EUnit)** — `rebar3 eunit` — 142 tests covering frame codec,
  close-code validation, handshake helpers (H1/H2/H3),
  permessage-deflate negotiation + codec.
- **Property (PropEr)** — `rebar3 proper -m ws_prop_tests` — 4
  properties: mask involution, client↔server encode/decode
  round-trip in both directions, chunked delivery equivalence.
- **End-to-end (Common Test)** — `rebar3 ct` — 34 cases total:
  - `ws_session_SUITE` (10) — server-side echo, fragmentation,
    close / ping / bad-UTF-8 / oversize.
  - `ws_client_SUITE` (3) — client↔server round-trip.
  - `ws_examples_SUITE` (12) — boots `examples/` modules and drives
    them: echo round-trip via `echo_client:send/2`, chat broadcast
    with multiple clients, 20 concurrent echo clients, fragmented
    text, ping/pong sequence, subprotocol negotiation, subprotocol
    rejection, TLS `wss://` round-trip, 512 KiB binary echo, close
    on invalid UTF-8.
  - `ws_docs_snippets_SUITE` (9) — mechanically exercises every code
    example in the README and `docs/guide.md` so documentation
    cannot silently rot.
- **Compliance (Autobahn)** —
  `WS_RUN_AUTOBAHN=1 rebar3 ct --suite=test/ws_compliance_SUITE` —
  runs the [Autobahn testsuite] via docker against an in-process echo
  server. 300 cases across sections 1–9 (framing, pings, reserved
  bits, opcodes, fragmentation, UTF-8, close handling, limits) all
  green.

## Documentation

- [docs/guide.md](docs/guide.md) — tutorial, every snippet tested.
- [docs/embedding.md](docs/embedding.md) — how to plug into
  `erlang_h1` / `erlang_h2` / `erlang_quic/h3` / Cowboy / Livery /
  your own HTTP layer.
- [docs/errors.md](docs/errors.md) — error taxonomy, close codes,
  handshake failure modes.
- [docs/features.md](docs/features.md) — RFC coverage, hardening
  list, out-of-scope list.

Full API reference is on hexdocs; regenerate locally with
`rebar3 ex_doc`.

## Embedder integration notes

- **HTTP/2.** The embedder's HTTP/2 stack must advertise
  `SETTINGS_ENABLE_CONNECT_PROTOCOL = 1` before RFC 8441 extended
  CONNECT is accepted. `erlang_h2` exposes this as the
  `enable_connect_protocol => true` server option.
- **HTTP/3.** `erlang_quic/h3` already enforces RFC 9220 validation.
  The `ws_h3_upgrade` helpers are there so embedders validate via the
  same surface and surface the same typed errors.
- **Stream handover.** Embedders must supply a `ws_transport`
  implementation whose `classify/2` maps their stream messages to the
  canonical `{ws_data | ws_closed | ws_error, Handle, ...}` shape.

## License

Apache-2.0. See `LICENSE` for the full text once published.

[Autobahn testsuite]: https://github.com/crossbario/autobahn-testsuite
