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

%% @doc Reference HTTP/1.1 WebSocket server over `gen_tcp'.
%%
%% A minimal acceptor-loop + upgrade driver built on top of the
%% library's own helpers. Intended both as a runnable example and as
%% the server-side driver for the end-to-end test suite. Embedders
%% with a full HTTP stack will not need it.
%%
%%   {ok, Pid} = ws_h1_tcp_server:start_link(#{
%%       port    => 8080,
%%       handler => my_handler,
%%       handler_opts => #{}
%%   }),
%%   {ok, ActualPort} = ws_h1_tcp_server:port(Pid),
%%   ...
%%   ok = ws_h1_tcp_server:stop(Pid).
%%
%% Options:
%%   port            :: inet:port_number(). Default 0 (OS-picked).
%%   ip              :: inet:ip_address() | any. Default any.
%%   handler         :: module(). Required.
%%   handler_opts    :: term(). Default #{}.
%%   subprotocols    :: [binary()]. Required subprotocols; the server
%%                      picks the first matching one from the client
%%                      offer.
%%   tls             :: [ssl:tls_server_option()]. If present, the
%%                      server terminates TLS on the connection (wss).
%%   parser_opts     :: map(). Passed through to `ws:accept/6'.
%%   timeout         :: timeout(). Handshake read timeout (default
%%                      15000 ms).
-module(ws_h1_tcp_server).

-export([start_link/1, stop/1, port/1]).

-type opts() :: #{
    port               => inet:port_number(),
    ip                 => inet:ip_address() | any,
    handler            := module(),
    handler_opts       => term(),
    subprotocols       => [binary()],
    tls                => [term()],
    parser_opts        => map(),
    timeout            => timeout(),
    max_handshake_size => pos_integer()
}.

%% Default guard against unbounded pre-upgrade read.
-define(DEFAULT_MAX_HANDSHAKE, 64 * 1024).

-export_type([opts/0]).

%% ---------------------------------------------------------------------
%% API

-spec start_link(opts()) -> {ok, pid()} | {error, term()}.
start_link(Opts) ->
    Parent = self(),
    Ref = make_ref(),
    Pid = erlang:spawn_link(fun() -> init(Parent, Ref, Opts) end),
    receive
        {Ref, {ok, _Port}} -> {ok, Pid};
        {Ref, {error, _} = E} -> E
    after 5000 ->
        exit(Pid, kill),
        {error, listen_timeout}
    end.

-spec stop(pid()) -> ok.
stop(Pid) ->
    Ref = erlang:monitor(process, Pid),
    Pid ! stop,
    receive
        {'DOWN', Ref, process, Pid, _} -> ok
    after 5000 ->
        exit(Pid, kill),
        ok
    end.

-spec port(pid()) -> {ok, inet:port_number()} | {error, term()}.
port(Pid) ->
    Ref = erlang:make_ref(),
    Pid ! {port, self(), Ref},
    receive
        {Ref, Reply} -> Reply
    after 1000 ->
        {error, timeout}
    end.

%% ---------------------------------------------------------------------
%% Listener process

init(Parent, Ref, Opts) ->
    IP = maps:get(ip, Opts, {0,0,0,0}),
    Port = maps:get(port, Opts, 0),
    ListenOpts = [binary, {active, false}, {reuseaddr, true},
                  {packet, 0}, {ip, IP}],
    case gen_tcp:listen(Port, ListenOpts) of
        {ok, Listen} ->
            {ok, ActualPort} = inet:port(Listen),
            Parent ! {Ref, {ok, ActualPort}},
            accept_loop(Listen, ActualPort, Opts);
        {error, _} = E ->
            Parent ! {Ref, E}
    end.

accept_loop(Listen, ActualPort, Opts) ->
    Timeout = maps:get(timeout, Opts, 15000),
    case gen_tcp:accept(Listen, 200) of
        {ok, Sock} ->
            spawn_upgrade(Sock, Opts, Timeout),
            check_ctl(Listen, ActualPort, Opts);
        {error, timeout} ->
            check_ctl(Listen, ActualPort, Opts);
        {error, closed} ->
            ok
    end.

check_ctl(Listen, ActualPort, Opts) ->
    receive
        stop ->
            gen_tcp:close(Listen),
            ok;
        {port, From, Ref} ->
            From ! {Ref, {ok, ActualPort}},
            accept_loop(Listen, ActualPort, Opts)
    after 0 ->
        accept_loop(Listen, ActualPort, Opts)
    end.

spawn_upgrade(Sock, Opts, Timeout) ->
    Handler = erlang:spawn(fun() ->
        receive
            {handle, S} -> serve(S, Opts, Timeout)
        end
    end),
    ok = gen_tcp:controlling_process(Sock, Handler),
    Handler ! {handle, Sock},
    ok.

serve(Sock, Opts, Timeout) ->
    {Transport, Handle, Rest0} = maybe_tls(Sock, Opts, Timeout),
    MaxHs = maps:get(max_handshake_size, Opts, ?DEFAULT_MAX_HANDSHAKE),
    case read_request(Transport, Handle, Rest0, Timeout, MaxHs) of
        {ok, Method, Path, Hdrs, Rest} ->
            handshake(Transport, Handle, Method, Path, Hdrs, Rest, Opts);
        {error, _} ->
            Transport:close(Handle)
    end.

maybe_tls(Sock, #{tls := TlsOpts} = _Opts, Timeout) ->
    case ssl:handshake(Sock, TlsOpts, Timeout) of
        {ok, TlsSock} -> {ws_transport_ssl, TlsSock, <<>>};
        _ ->
            gen_tcp:close(Sock),
            exit(normal)
    end;
maybe_tls(Sock, _Opts, _Timeout) ->
    {ws_transport_gen_tcp, Sock, <<>>}.

handshake(Transport, Handle, Method, Path, Hdrs, Rest, Opts) ->
    Sub = maps:get(subprotocols, Opts, []),
    Validate = case Sub of
        [] -> ws_h1_upgrade:validate_request(Hdrs);
        _  -> ws_h1_upgrade:validate_request(Hdrs,
                  #{required_subprotocols => Sub})
    end,
    case Validate of
        {ok, Info} ->
            RespHdrs = ws_h1_upgrade:response_headers(Info),
            Resp = encode_response(101, <<"Switching Protocols">>, RespHdrs),
            case Transport:send(Handle, Resp) of
                ok -> start_session(Transport, Handle, Method, Path, Hdrs,
                                    Info, Rest, Opts);
                _  -> Transport:close(Handle)
            end;
        {error, Reason} ->
            Body = iolist_to_binary(io_lib:format("~p", [Reason])),
            Resp = encode_response(400, <<"Bad Request">>,
                     [{<<"content-length">>,
                       integer_to_binary(byte_size(Body))},
                      {<<"content-type">>, <<"text/plain">>},
                      {<<"connection">>, <<"close">>}]),
            _ = Transport:send(Handle, [Resp, Body]),
            Transport:close(Handle)
    end.

start_session(Transport, Handle, Method, Path, Hdrs, Info, Rest, Opts) ->
    HandlerMod  = maps:get(handler, Opts),
    HandlerOpts = maps:get(handler_opts, Opts, #{}),
    ParserOpts  = maps:get(parser_opts, Opts, #{}),
    Req = #{method => Method,
            path => Path,
            headers => Hdrs,
            upgrade_info => Info},
    case ws:accept(Transport, Handle, Req, HandlerMod, HandlerOpts,
                   #{parser_opts => ParserOpts}) of
        {ok, Pid} ->
            case Rest of
                <<>> -> ok;
                _ ->
                    Msg = case Transport of
                        ws_transport_gen_tcp -> {tcp, Handle, Rest};
                        ws_transport_ssl     -> {ssl, Handle, Rest}
                    end,
                    Pid ! Msg
            end;
        {error, _} ->
            Transport:close(Handle)
    end.

%% ---------------------------------------------------------------------
%% HTTP parsing / encoding — enough for the handshake line + headers.

read_request(Transport, Handle, Seed, Timeout, MaxHs) ->
    read_request(Transport, Handle, Seed, Timeout,
                 erlang:monotonic_time(millisecond), MaxHs).

read_request(Transport, Handle, Acc, Timeout, Start, MaxHs) ->
    case erlang:decode_packet(http_bin, Acc, []) of
        {more, _} ->
            case grow(Transport, Handle, Acc, Timeout, Start, MaxHs) of
                {ok, Acc2} ->
                    read_request(Transport, Handle, Acc2, Timeout, Start, MaxHs);
                Err -> Err
            end;
        {ok, {http_request, M, P, _V}, Rest} ->
            Path = http_path(P),
            Method = http_method(M),
            read_headers(Transport, Handle, Rest, Method, Path, [],
                         Timeout, Start, MaxHs);
        {ok, {http_error, _}, _} ->
            {error, bad_request};
        {error, R} ->
            {error, R}
    end.

read_headers(Transport, Handle, Buf, M, P, Acc, Timeout, Start, MaxHs) ->
    case erlang:decode_packet(httph_bin, Buf, []) of
        {more, _} ->
            case grow(Transport, Handle, Buf, Timeout, Start, MaxHs) of
                {ok, Buf2} ->
                    read_headers(Transport, Handle, Buf2,
                                 M, P, Acc, Timeout, Start, MaxHs);
                Err -> Err
            end;
        {ok, http_eoh, Rest} ->
            {ok, M, P, lists:reverse(Acc), Rest};
        {ok, {http_header, _, Name, _, Value}, Rest} ->
            N = header_name(Name),
            read_headers(Transport, Handle, Rest, M, P,
                         [{N, Value} | Acc], Timeout, Start, MaxHs);
        {error, R} ->
            {error, R}
    end.

grow(Transport, Handle, Acc, Timeout, Start, MaxHs) ->
    case Transport:recv(Handle, remaining(Timeout, Start)) of
        {ok, Bin} ->
            Acc2 = <<Acc/binary, Bin/binary>>,
            case byte_size(Acc2) > MaxHs of
                true  -> {error, handshake_too_big};
                false -> {ok, Acc2}
            end;
        Err -> Err
    end.

http_path({abs_path, P})    -> P;
http_path({absoluteURI, _, _, _, P}) -> P;
http_path('*')              -> <<"*">>;
http_path(P) when is_binary(P) -> P.

http_method(A) when is_atom(A)   -> atom_to_binary(A, utf8);
http_method(B) when is_binary(B) -> B.

header_name(A) when is_atom(A)   -> atom_to_binary(A, utf8);
header_name(B) when is_binary(B) -> B.

encode_response(Status, Reason, Hdrs) ->
    [<<"HTTP/1.1 ">>, integer_to_binary(Status), <<" ">>, Reason, <<"\r\n">>,
     [[N, <<": ">>, V, <<"\r\n">>] || {N, V} <- Hdrs],
     <<"\r\n">>].

remaining(infinity, _) -> infinity;
remaining(Timeout, Start) ->
    Elapsed = erlang:monotonic_time(millisecond) - Start,
    max(0, Timeout - Elapsed).
