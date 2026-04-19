# Guide

A walk-through of `erlang_ws` from handler to shipping server.

- [Mental model](#mental-model)
- [A minimal handler](#a-minimal-handler)
- [Running a server](#running-a-server)
- [Running a client](#running-a-client)
- [Sending frames from the outside](#sending-frames-from-the-outside)
- [Closing the connection](#closing-the-connection)
- [Subprotocols and extensions](#subprotocols-and-extensions)
- [TLS (`wss://`)](#tls-wss)
- [Limits and timeouts](#limits-and-timeouts)
- [Bringing your own HTTP layer](#bringing-your-own-http-layer)

Every snippet in this guide is mechanically exercised by
`test/ws_docs_snippets_SUITE.erl`. If you copy one out and it fails
for you, that is a bug in the library or the documentation.

## Mental model

`erlang_ws` is divided into four layers; each talks only to the one
directly below it.

```
┌─────────────────────────────────────────┐
│  ws_handler callback module (your code) │
├─────────────────────────────────────────┤
│  ws_session  (gen_statem)               │
├─────────────────────────────────────────┤
│  ws_frame    (RFC 6455 codec)           │
├─────────────────────────────────────────┤
│  ws_transport  (gen_tcp / ssl / H2 / H3)│
└─────────────────────────────────────────┘
```

- `ws_handler` is a behaviour — the four callbacks the library calls
  to notify your code of events.
- `ws_session` is the per-connection state machine. It owns a
  transport handle, drains bytes, reassembles fragments, answers
  pings, routes decoded messages to your handler and forwards your
  replies back to the peer.
- `ws_frame` is the pure-functional codec. It knows nothing about
  processes or sockets.
- `ws_transport` is a thin behaviour hiding the differences between
  `gen_tcp`, `ssl`, and opaque stream handles exposed by an HTTP/2
  or HTTP/3 library.

Upgrade helpers live beside these: `ws_h1_upgrade` parses an
HTTP/1.1 `Upgrade: websocket` request, `ws_h2_upgrade` and
`ws_h3_upgrade` validate RFC 8441 / RFC 9220 extended CONNECT.

## A minimal handler

```erlang
-module(greet_handler).
-behaviour(ws_handler).

-export([init/2, handle_in/2, handle_info/2, terminate/2]).

%% ---- required callbacks ---------------------------------------------

%% Called once, right after the peer's upgrade has been accepted and
%% before any inbound frame is dispatched. `Req` is whatever the
%% embedder supplied to `ws:accept/5` (method, path, headers, ...).
%% `Opts` is `HandlerOpts` from the same call.
init(_Req, Opts) ->
    {ok, Opts}.

%% Called for every complete message decoded from the peer. Return:
%%   {ok,     State}           — do nothing else
%%   {reply,  Frame | [Frame], State}  — send one or more frames
%%   {stop,   Reason,          State}  — terminate the session
handle_in({text, Data}, State) ->
    Reply = <<"hello ", Data/binary>>,
    {reply, {text, Reply}, State};
handle_in({binary, _}, State) ->
    {ok, State};
handle_in({ping, _}, State) ->
    %% The session already answered with a pong before calling us;
    %% this callback exists only so we can audit pings if we want to.
    {ok, State};
handle_in({pong, _}, State) ->
    {ok, State};
handle_in(close, State) ->
    {ok, State};
handle_in({close, _Code, _Reason}, State) ->
    {ok, State}.

%% Any Erlang message that arrives while the session is alive and is
%% not a transport event ends up here. Return a `{reply, ...}` to turn
%% a message into a WebSocket frame.
handle_info(_Msg, State) ->
    {ok, State}.

%% Called exactly once on session shutdown.
terminate(_Reason, _State) ->
    ok.
```

Every return shape that's legal for `handle_in/2` is also legal for
`init/2` and `handle_info/2`.

## Running a server

The bundled reference HTTP/1.1 listener is the fastest way to get a
handler in front of a real socket:

```erlang
start_echo() ->
    {ok, _} = application:ensure_all_started(ws),
    ws_h1_tcp_server:start_link(
        #{port         => 0,                 %% 0 = OS-picked port
          handler      => greet_handler,
          handler_opts => #{}
         }).
```

`start_link/1` returns `{ok, Pid}` when the listen socket is bound.
Ask the server for its actual port with `ws_h1_tcp_server:port/1`:

```erlang
{ok, Server} = start_echo(),
{ok, Port}   = ws_h1_tcp_server:port(Server).
```

Stop it with `ws_h1_tcp_server:stop/1`.

## Running a client

```erlang
-module(client_relay).
-behaviour(ws_handler).
-export([init/2, handle_in/2, handle_info/2, terminate/2]).

init(_Req, #{notify := Pid} = State) when is_pid(Pid) ->
    {ok, State}.

handle_in(Frame, State = #{notify := Pid}) ->
    Pid ! {ws, Frame},
    {ok, State}.

handle_info(_, State) -> {ok, State}.
terminate(_, _) -> ok.
```

Connect:

```erlang
talk(Url) ->
    {ok, _} = application:ensure_all_started(ws),
    {ok, Conn} = ws:connect(Url,
        #{handler      => client_relay,
          handler_opts => #{notify => self()}}),
    ws:send(Conn, {text, <<"hello">>}),
    receive
        {ws, {text, Reply}} -> Reply
    after 5000 ->
        ws:close(Conn, 1000, <<>>),
        timeout
    end.
```

`ws:connect/2` supports `ws://` and `wss://`. Full option list:

| Key              | Default  | Purpose                             |
|------------------|----------|-------------------------------------|
| `handler`        | required | handler module                      |
| `handler_opts`   | `#{}`    | passed to `init/2`                  |
| `subprotocols`   | `[]`     | offered in `Sec-WebSocket-Protocol` |
| `extensions`     | `[]`     | offered in `Sec-WebSocket-Extensions` |
| `origin`         | unset    | `Origin:` header                    |
| `extra_headers`  | `[]`     | verbatim extra request headers      |
| `timeout`        | 15000    | handshake read timeout (ms)         |
| `ssl_opts`       | see note | extra `ssl:connect` options         |
| `parser_opts`    | `#{}`    | `ws_frame:init_parser/1` options    |

**TLS defaults.** `wss://` connects with `verify_peer` + OS CA trust
+ SNI; pass `ssl_opts => [...]` to override any key (the user's
`ssl_opts` win).

## Sending frames from the outside

Anything that has a handle on the session pid can push frames into
the connection:

```erlang
ws:send(Conn, {text, <<"tick">>}),
ws:send(Conn, [{text, <<"a">>}, {binary, <<1,2,3>>}]).
```

A list sends frames in order. This is also the standard idiom for
cross-process fan-out — route a message to the session pid and
return a `{reply, Frame, State}` from `handle_info/2` so the frame
reaches the peer:

```erlang
handle_info({push, Text}, State) ->
    {reply, {text, Text}, State}.
```

## Closing the connection

```erlang
ws:close(Conn, 1000, <<"bye">>).
```

That sends a close frame to the peer, switches the session into
`closing` state, and — once the peer's close frame arrives or the
socket closes — exits the session normally.

If the peer initiates the close, the session echoes a close frame
back (once) and terminates. Your handler's `terminate/2` is called
with `normal`.

`Code` must be a valid on-wire close code (`ws_close:valid_on_wire/1`
— 1000–1003, 1007–1011, or 3000–4999). Passing an invalid code
downgrades to 1002 (protocol error).

## Subprotocols and extensions

Server-side, tell `ws_h1_tcp_server` (or your embedder) which
subprotocols you accept; the first client-offered match wins and is
echoed back in the 101 response:

```erlang
{ok, _} = ws_h1_tcp_server:start_link(
    #{port => 0,
      handler => my_handler, handler_opts => #{},
      subprotocols => [<<"chat.v2">>, <<"chat">>]}).
```

Client-side, offer a list and inspect the negotiated subprotocol in
the handler's `init/2` via the `Req` map — it contains the parsed
101 response under `response`:

```erlang
init(#{response := #{subprotocol := Sub}} = _Req, State) ->
    io:format("server picked ~s~n", [Sub]),
    {ok, State};
init(_Req, State) ->
    {ok, State}.
```

Extensions (as strings only — the library doesn't run them yet
except for `ws_deflate`) are passed through the same way.

## TLS (`wss://`)

Listener side:

```erlang
{ok, _} = ws_h1_tcp_server:start_link(
    #{port    => 0,
      handler => my_handler, handler_opts => #{},
      tls     => [{cert, CertDer}, {key, {'RSAPrivateKey', KeyDer}},
                  {versions, ['tlsv1.3']}]}).
```

Client side: just use a `wss://` URL. To disable verification in tests:

```erlang
ws:connect(<<"wss://127.0.0.1:8443/">>,
    #{handler => my_handler,
      handler_opts => #{},
      ssl_opts => [{verify, verify_none}]}).
```

## Limits and timeouts

`ws_frame:init_parser/1` takes `max_frame` and `max_message`; wire
them through `parser_opts` in `ws:accept/6` or `ws:connect/2`:

```erlang
ws:connect(Url,
    #{handler     => my_handler,
      handler_opts => #{},
      parser_opts => #{max_frame => 1024 * 1024,
                       max_message => 16 * 1024 * 1024}}).
```

Exceeding `max_frame` aborts the session with close code **1009
Message Too Big** and closes the socket.

## Bringing your own HTTP layer

`ws_h1_tcp_server` is a reference. Real embedders wire `ws:accept/5`
directly from the point where their HTTP/1.1, HTTP/2, or HTTP/3 stack
has finished parsing the upgrade request. See
[docs/embedding.md](embedding.md) for the four integration patterns.
