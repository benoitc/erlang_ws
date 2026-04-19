%% Copyright 2026 Benoit Chesneau
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.

%% @doc WebSocket client connect for `ws://' / `wss://' URLs.
%%
%% The client connects over plain TCP (`ws') or TLS (`wss'), sends the
%% HTTP/1.1 upgrade request, validates the 101 response, and starts a
%% `ws_session' running in client mode.
%%
%% HTTP/2 and HTTP/3 client flows piggy-back on an already-established
%% H2/H3 connection owned by the embedder; they are driven through
%% `ws_h2_upgrade' / `ws_h3_upgrade' plus a transport adapter the
%% embedder supplies, not through this module.
-module(ws_client).

-export([connect/2]).

-type url() :: binary() | string().
-type opts() :: #{
    handler            := module(),
    handler_opts       => term(),
    subprotocols       => [binary()],
    extensions         => [binary()],
    origin             => binary(),
    extra_headers      => [{binary(), binary()}],
    timeout            => timeout(),
    max_handshake_size => pos_integer(),
    ssl_opts           => list(),
    parser_opts        => map()
}.

%% Default guard against a peer that feeds us bytes but never
%% completes the 101 response — stop accumulating at 64 KiB.
-define(DEFAULT_MAX_HANDSHAKE, 64 * 1024).

-export_type([url/0, opts/0]).

-spec connect(url(), opts()) -> {ok, pid()} | {error, term()}.
connect(Url, Opts) ->
    case parse_url(Url) of
        {ok, Scheme, Host, Port, Path} ->
            Timeout = maps:get(timeout, Opts, 15000),
            MaxHs = maps:get(max_handshake_size, Opts, ?DEFAULT_MAX_HANDSHAKE),
            case dial(Scheme, Host, Port, Opts, Timeout) of
                {ok, Transport, Handle} ->
                    upgrade(Transport, Handle, Host, Port, Path, Opts,
                            Timeout, MaxHs);
                {error, _} = E ->
                    E
            end;
        {error, _} = E -> E
    end.

%% ---------------------------------------------------------------------
%% URL parsing

parse_url(Url) when is_list(Url) ->
    parse_url(list_to_binary(Url));
parse_url(<<"ws://", Rest/binary>>) ->
    parse_rest(ws, Rest, 80);
parse_url(<<"wss://", Rest/binary>>) ->
    parse_rest(wss, Rest, 443);
parse_url(_) ->
    {error, invalid_scheme}.

parse_rest(Scheme, Rest, DefaultPort) ->
    {HostPort, Path} =
        case binary:split(Rest, <<"/">>) of
            [HP] -> {HP, <<"/">>};
            [HP, Rem] -> {HP, <<"/", Rem/binary>>}
        end,
    {Host, Port} = case binary:split(HostPort, <<":">>) of
        [H] -> {H, DefaultPort};
        [H, P] -> {H, binary_to_integer(P)}
    end,
    {ok, Scheme, Host, Port, Path}.

%% ---------------------------------------------------------------------
%% Dial + upgrade

dial(ws, Host, Port, _Opts, Timeout) ->
    case gen_tcp:connect(binary_to_list(Host), Port,
                         [binary, {active, false}, {packet, 0}], Timeout) of
        {ok, Sock} -> {ok, ws_transport_gen_tcp, Sock};
        Err -> Err
    end;
dial(wss, Host, Port, Opts, Timeout) ->
    BaseOpts = [binary, {active, false},
                {verify, verify_peer},
                {cacerts, public_key:cacerts_get()},
                {server_name_indication, binary_to_list(Host)}],
    SslOpts = merge_ssl_opts(BaseOpts, maps:get(ssl_opts, Opts, [])),
    case ssl:connect(binary_to_list(Host), Port, SslOpts, Timeout) of
        {ok, Sock} -> {ok, ws_transport_ssl, Sock};
        Err -> Err
    end.

merge_ssl_opts(Base, User) ->
    %% Let the user override any base option.
    UserKeys = [element(1, T) || T <- User, is_tuple(T)],
    Filtered = [B || B <- Base,
                     not is_tuple(B) orelse
                     not lists:member(element(1, B), UserKeys)],
    Filtered ++ User.

upgrade(Transport, Handle, Host, Port, Path, Opts, Timeout, MaxHs) ->
    ClientOpts = maps:with([subprotocols, extensions, origin, extra_headers], Opts),
    {Key, Hdrs} = ws_h1_upgrade:build_request(Host, Port, Path, ClientOpts),
    Request = format_request(Path, Hdrs),
    case Transport:send(Handle, Request) of
        ok ->
            case read_response(Transport, Handle, Timeout, MaxHs) of
                {ok, Status, RespHdrs, _Rest} ->
                    case ws_h1_upgrade:validate_response(Status, RespHdrs) of
                        {ok, Info} ->
                            verify_accept(Key, Info, Transport, Handle, Opts);
                        Err ->
                            _ = Transport:close(Handle),
                            Err
                    end;
                Err ->
                    _ = Transport:close(Handle),
                    Err
            end;
        Err ->
            _ = Transport:close(Handle),
            Err
    end.

verify_accept(Key, Info, Transport, Handle, Opts) ->
    Expected = ws_h1_upgrade:accept_key(Key),
    case maps:get(accept, Info) of
        Expected ->
            start_session(Transport, Handle, Info, Opts);
        _ ->
            _ = Transport:close(Handle),
            {error, sec_websocket_accept_mismatch}
    end.

start_session(Transport, Handle, Info, Opts) ->
    HandlerMod = maps:get(handler, Opts),
    HandlerOpts = maps:get(handler_opts, Opts, #{}),
    ParserOpts = maps:get(parser_opts, Opts, #{}),
    Req = #{response => Info},
    StartOpts = #{
        transport    => Transport,
        handle       => Handle,
        role         => client,
        handler      => HandlerMod,
        handler_opts => HandlerOpts,
        req          => Req,
        parser_opts  => ParserOpts
    },
    case ws_session:start_link(StartOpts) of
        {ok, Pid} ->
            case Transport:controlling_process(Handle, Pid) of
                ok ->
                    ok = ws_session:activate(Pid),
                    {ok, Pid};
                Err ->
                    ws_session:stop(Pid),
                    Err
            end;
        Err -> Err
    end.

%% ---------------------------------------------------------------------
%% Minimal HTTP/1.1 response reader: we only need status line and
%% headers until the blank-line boundary, then hand the remainder back
%% to the session. The handshake response cannot carry a body.

format_request(Path, Hdrs) ->
    [<<"GET ">>, Path, <<" HTTP/1.1\r\n">>,
     [[N, <<": ">>, V, <<"\r\n">>] || {N, V} <- Hdrs],
     <<"\r\n">>].

read_response(Transport, Handle, Timeout, MaxHs) ->
    Start = erlang:monotonic_time(millisecond),
    read_response_loop(Transport, Handle, <<>>, Timeout, Start, MaxHs).

read_response_loop(Transport, Handle, Acc, Timeout, Start, MaxHs) ->
    case erlang:decode_packet(http_bin, Acc, []) of
        {more, _} ->
            case grow(Transport, Handle, Acc, Timeout, Start, MaxHs) of
                {ok, Acc2} ->
                    read_response_loop(Transport, Handle, Acc2,
                                       Timeout, Start, MaxHs);
                Err -> Err
            end;
        {ok, {http_response, _Ver, Status, _Reason}, Rest} ->
            read_headers(Transport, Handle, Rest, Status, [],
                         Timeout, Start, MaxHs);
        {ok, {http_error, _}, _} ->
            {error, bad_http_response};
        {error, R} ->
            {error, R}
    end.

read_headers(Transport, Handle, Buf, Status, Acc, Timeout, Start, MaxHs) ->
    case erlang:decode_packet(httph_bin, Buf, []) of
        {more, _} ->
            case grow(Transport, Handle, Buf, Timeout, Start, MaxHs) of
                {ok, Buf2} ->
                    read_headers(Transport, Handle, Buf2,
                                 Status, Acc, Timeout, Start, MaxHs);
                Err -> Err
            end;
        {ok, http_eoh, Rest} ->
            {ok, Status, lists:reverse(Acc), Rest};
        {ok, {http_header, _, Name, _, Value}, Rest} ->
            Name2 = normalize_header_name(Name),
            read_headers(Transport, Handle, Rest, Status,
                         [{Name2, Value} | Acc], Timeout, Start, MaxHs);
        {error, R} ->
            {error, R}
    end.

grow(Transport, Handle, Acc, Timeout, Start, MaxHs) ->
    case do_recv(Transport, Handle, remaining(Timeout, Start)) of
        {ok, Bin} ->
            Acc2 = <<Acc/binary, Bin/binary>>,
            case byte_size(Acc2) > MaxHs of
                true  -> {error, handshake_response_too_big};
                false -> {ok, Acc2}
            end;
        Err -> Err
    end.

normalize_header_name(Name) when is_atom(Name) ->
    string:lowercase(atom_to_binary(Name, utf8));
normalize_header_name(Name) when is_binary(Name) ->
    string:lowercase(Name).

do_recv(Mod, Handle, Timeout) ->
    case erlang:function_exported(Mod, recv, 2) of
        true  -> Mod:recv(Handle, Timeout);
        false -> {error, {transport_does_not_support_recv, Mod}}
    end.

remaining(infinity, _) -> infinity;
remaining(Timeout, Start) ->
    Elapsed = erlang:monotonic_time(millisecond) - Start,
    max(0, Timeout - Elapsed).
