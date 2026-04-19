# Embedding

`erlang_ws` does not ship an HTTP server. It plugs into whatever
HTTP/1.1, HTTP/2, or HTTP/3 stack owns the underlying stream. This
page gives you the four integration patterns we know about.

- [The contract](#the-contract)
- [HTTP/1.1: from request headers to `ws:accept/5`](#http11-from-request-headers-to-wsaccept5)
- [HTTP/2: RFC 8441 extended CONNECT](#http2-rfc-8441-extended-connect)
- [HTTP/3: RFC 9220 extended CONNECT](#http3-rfc-9220-extended-connect)
- [Writing your own transport](#writing-your-own-transport)

## The contract

Every embedder does four things:

1. **Parse the upgrade request.** Your HTTP stack hands you request
   method, target, and headers (HTTP/1.1) or pseudo-headers
   (HTTP/2, HTTP/3).
2. **Validate.** Call `ws_h1_upgrade:validate_request/1,2` or
   `ws_h2_upgrade:validate_request/1,2` (`ws_h3_upgrade` delegates
   to the H2 shape). On success you get a map carrying the key,
   accept value, offered subprotocols, extensions, and optionally
   the chosen subprotocol.
3. **Write the 101 / 200 response.** `response_headers/1,2` returns
   the header list; your stack serialises it.
4. **Hand the stream to the session.** Call
   `ws:accept(TransportMod, Handle, Req, HandlerMod, HandlerOpts)`.
   The session takes ownership of the stream and drives the codec
   from there.

The only requirement on `TransportMod` is that it implements the
`ws_transport` behaviour (below).

## HTTP/1.1: from request headers to `ws:accept/5`

You already have `Method`, `Path`, `Headers`. Given a raw
`gen_tcp` socket:

```erlang
upgrade(Sock, Headers) ->
    case ws_h1_upgrade:validate_request(Headers,
             #{required_subprotocols => [<<"chat">>]}) of
        {ok, Info} ->
            Resp = ws_h1_upgrade:response_headers(Info),
            ok = gen_tcp:send(Sock, format_101(Resp)),
            ws:accept(ws_transport_gen_tcp, Sock,
                      #{headers => Headers, upgrade_info => Info},
                      chat_handler, #{});
        {error, Reason} ->
            gen_tcp:send(Sock, format_4xx(400, Reason)),
            gen_tcp:close(Sock)
    end.

format_101(Hdrs) ->
    [<<"HTTP/1.1 101 Switching Protocols\r\n">>,
     [[N, <<": ">>, V, <<"\r\n">>] || {N, V} <- Hdrs],
     <<"\r\n">>].

format_4xx(Code, Reason) ->
    Body = iolist_to_binary(io_lib:format("~p", [Reason])),
    [<<"HTTP/1.1 ">>, integer_to_binary(Code), <<" Bad Request\r\n",
       "Content-Length: ">>, integer_to_binary(byte_size(Body)),
       <<"\r\nConnection: close\r\n\r\n">>, Body].
```

A couple of gotchas learned the hard way:

- `ws:accept/5` starts the session with `ws_session:start/1` (no
  link) because the typical embedder spawns a short-lived handler
  process that dies after the accept. If you want the session tied
  to *your* process, monitor `Pid` and act on `DOWN` messages.
- Any bytes you read past the `\r\n\r\n` blank line while parsing
  the request are the peer's first WebSocket frame — forward them
  to the session process as `{tcp, Handle, Rest}` so the transport's
  `classify/2` can pick them up.
- Don't switch the socket to active mode before calling
  `ws:accept/5`. The session handles that after
  `controlling_process/2`.

For a ready-made version of this pattern, read
`src/ws_h1_tcp_server.erl` — it's the exact code above wrapped in an
acceptor loop.

## HTTP/2: RFC 8441 extended CONNECT

Extended CONNECT is **opt-in**. Your HTTP/2 stack must advertise
`SETTINGS_ENABLE_CONNECT_PROTOCOL = 1` at connection setup
(`erlang_h2` exposes this as the `enable_connect_protocol => true`
server option).

When the stack gives you the pseudo-headers of a CONNECT stream
carrying `:protocol = websocket`:

```erlang
upgrade_h2(StreamPseudoHdrs, RegularHdrs, H2Stream) ->
    All = StreamPseudoHdrs ++ RegularHdrs,
    case ws_h2_upgrade:validate_request(All) of
        {ok, Info} ->
            RespHdrs = ws_h2_upgrade:response_headers(Info),
            ok = h2:send_response(H2Stream, RespHdrs, no_body),
            ws:accept(my_h2_transport, H2Stream,
                      #{headers => All, upgrade_info => Info},
                      chat_handler, #{});
        {error, Reason} ->
            h2:send_response(H2Stream,
                [{<<":status">>, <<"400">>}], {body, io_lib:format("~p", [Reason])})
    end.
```

Your `my_h2_transport` module implements `ws_transport` and wraps
the HTTP/2 stream handle — `send/2` translates to `h2:send_data/3`
with `end_stream=false`, `classify/2` turns inbound H2 DATA frame
messages into `{ws_data, Handle, Bin}`, and so on.

Client side, `ws_client` does not cover H2 yet. Build the request
pseudo-headers with `ws_h2_upgrade:client_request/4`, push them on
an extended-CONNECT stream, wait for the 2xx response, then call
`ws:accept/5` from the client side with `role => client` (set via
your transport's metadata; today you'd drive the session by calling
`ws_session:start/1` directly rather than `ws:accept/5`).

## HTTP/3: RFC 9220 extended CONNECT

RFC 9220 reuses the RFC 8441 pattern over HTTP/3 streams. `erlang_quic`
already implements the wire-level parts, including advertising
`SETTINGS_ENABLE_CONNECT_PROTOCOL` in H3 SETTINGS and validating
incoming extended CONNECT streams.

`ws_h3_upgrade` is a thin delegation to `ws_h2_upgrade` because the
pseudo-header shape is identical; the difference is the transport
(QUIC streams instead of H2 streams). Wire it up the same way as H2
above, substituting your H3 stream helpers.

## Writing your own transport

Implement the `ws_transport` behaviour:

```erlang
-module(my_transport).
-behaviour(ws_transport).

-export([send/2, activate/1, close/1, controlling_process/2, classify/2]).
-export([recv/2, peername/1]).

send(Handle, Iodata)              -> ... ok | {error, term()}.
activate(Handle)                  -> ... ok | {error, term()}.
close(Handle)                     -> ok.
controlling_process(Handle, Pid)  -> ... ok | {error, term()}.

classify({my_msg, H, Bin}, H)    -> {ws_data, H, Bin};
classify({my_closed, H}, H)      -> {ws_closed, H};
classify({my_error, H, R}, H)    -> {ws_error, H, R};
classify(_, _)                   -> ignore.

recv(Handle, Timeout)             -> ... {ok, binary()} | {error, term()}.  %% optional
peername(Handle)                  -> ... {ok, {ip(), port()}} | {error, term()}.  %% optional
```

- `activate/1` must put the stream into *pull* mode: deliver at most
  one batch of bytes, then wait for the next `activate/1`. For
  `gen_tcp` this is `{active, once}`. For H2/H3 streams it typically
  means "ask the parent connection for another chunk on this
  stream ID".
- `classify/2` is called from the session's `handle_info` on *every*
  message. Return `ignore` for messages that are not yours — the
  session will dispatch them to the user handler's `handle_info/2`.
- `recv/2` is only used by `ws_client` during its synchronous HTTP/1.1
  handshake. You can omit it if your transport is only ever used
  server-side or is driven through a stream handle (H2/H3).

Reference transports:

- `ws_transport_gen_tcp` — plain TCP.
- `ws_transport_ssl` — OTP `ssl`.
