%% @doc Client ↔ server round-trip over plain TCP.
%%
%% Starts an echo server (the same raw listener used by
%% `ws_session_SUITE') and connects to it with `ws_client:connect/2'.
%% Verifies that the handshake completes and frames round-trip
%% correctly through the full client session, including client-side
%% masking and server-side unmasking.
-module(ws_client_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).

-export([client_handshake_and_echo/1,
         client_ping_gets_pong/1,
         client_close_roundtrip/1,
         connect_bad_port_is_error/1,
         connect_ipv6_loopback/1,
         close_timeout_finishes_session/1]).

all() ->
    [client_handshake_and_echo,
     client_ping_gets_pong,
     client_close_roundtrip,
     connect_bad_port_is_error,
     connect_ipv6_loopback,
     close_timeout_finishes_session].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(ws),
    Config.

end_per_suite(_Config) ->
    ok = application:stop(ws).

init_per_testcase(_TC, Config) ->
    {Server, Port} = start_listener(self()),
    [{listener, Server}, {port, Port} | Config].

end_per_testcase(_TC, Config) ->
    catch exit(?config(listener, Config), shutdown),
    ok.

%% ---------------------------------------------------------------------
%% Tests

client_handshake_and_echo(Config) ->
    Pid = connect_client(Config),
    ws_session:send(Pid, {text, <<"hello">>}),
    {text, <<"hello">>} = wait_for_frame(2000),
    ok = ws_session:stop(Pid).

client_ping_gets_pong(Config) ->
    Pid = connect_client(Config),
    ws_session:send(Pid, {ping, <<"ping">>}),
    %% server_echo_handler forwards every inbound frame to the test
    %% process; a pong from the server will show up here.
    {pong, <<"ping">>} = wait_for_frame(2000),
    ok = ws_session:stop(Pid).

client_close_roundtrip(Config) ->
    Pid = connect_client(Config),
    ws_session:close(Pid, 1000, <<"bye">>),
    %% Session terminates after exchanging close frames.
    ok = wait_for_session_exit(Pid, 2000).

connect_bad_port_is_error(_Config) ->
    %% Non-numeric port is a typed error, not a crash. The parse fails
    %% before any socket call, so no listener is needed.
    ?assertMatch({error, {invalid_port, _}},
                 ws_client:connect(<<"ws://127.0.0.1:notaport/">>,
                     #{handler => client_forwarder_handler,
                       handler_opts => #{notify => self()}})).

connect_ipv6_loopback(_Config) ->
    case start_listener_ip(self(), {0,0,0,0,0,0,0,1}) of
        {error, Reason} ->
            {skip, {no_ipv6_loopback, Reason}};
        {Listener, Port} ->
            try
                Url = iolist_to_binary(["ws://[::1]:",
                                        integer_to_list(Port), "/"]),
                {ok, Pid} = ws_client:connect(Url,
                    #{handler => client_forwarder_handler,
                      handler_opts => #{notify => self()}}),
                ws_session:send(Pid, {text, <<"v6">>}),
                {text, <<"v6">>} = wait_for_frame(2000),
                ok = ws_session:stop(Pid)
            after
                catch exit(Listener, shutdown)
            end
    end.

close_timeout_finishes_session(_Config) ->
    %% Peer completes the handshake then goes silent (never echoes our
    %% close). The client must still exit within close_timeout.
    {Listener, Port} = start_silent_listener(),
    try
        Url = iolist_to_binary(["ws://127.0.0.1:",
                                integer_to_list(Port), "/"]),
        {ok, Pid} = ws_client:connect(Url,
            #{handler => client_forwarder_handler,
              handler_opts => #{notify => self()},
              close_timeout => 300}),
        MRef = erlang:monitor(process, Pid),
        ws:close(Pid, 1000, <<"bye">>),
        receive {'DOWN', MRef, process, Pid, _} -> ok
        after 2000 -> error(session_did_not_exit)
        end
    after
        Listener ! stop
    end.

%% ---------------------------------------------------------------------
%% Helpers

connect_client(Config) ->
    Port = ?config(port, Config),
    TestPid = self(),
    Url = iolist_to_binary(["ws://127.0.0.1:", integer_to_list(Port), "/"]),
    {ok, Pid} = ws_client:connect(Url,
        #{handler      => client_forwarder_handler,
          handler_opts => #{notify => TestPid}}),
    Pid.

wait_for_frame(Timeout) ->
    receive
        {ws_client_msg, F} -> F
    after Timeout ->
        error(timeout)
    end.

wait_for_session_exit(Pid, Timeout) ->
    MRef = erlang:monitor(process, Pid),
    receive
        {'DOWN', MRef, process, Pid, _} -> ok
    after Timeout ->
        error(session_did_not_exit)
    end.

start_listener(ParentPid) ->
    Parent = self(),
    Pid = spawn(fun() ->
        {ok, Listen} = gen_tcp:listen(0,
            [binary, {active, false}, {reuseaddr, true}, {packet, 0}]),
        {ok, P} = inet:port(Listen),
        Parent ! {ready, P},
        listener_loop(Listen, ParentPid)
    end),
    Port = receive {ready, P} -> P after 2000 -> error(listener_not_ready) end,
    {Pid, Port}.

%% Echo listener bound to a specific IP (used for the IPv6 case). Returns
%% {error, Reason} when the bind fails, e.g. no IPv6 loopback present.
start_listener_ip(ParentPid, IP) ->
    Parent = self(),
    Ref = make_ref(),
    Pid = spawn(fun() ->
        case gen_tcp:listen(0, [binary, {active, false}, {reuseaddr, true},
                                {packet, 0}, {ip, IP}]) of
            {ok, Listen} ->
                {ok, P} = inet:port(Listen),
                Parent ! {Ref, {ok, P}},
                listener_loop(Listen, ParentPid);
            {error, _} = E ->
                Parent ! {Ref, E}
        end
    end),
    receive
        {Ref, {ok, Port}}     -> {Pid, Port};
        {Ref, {error, _} = E} -> E
    after 2000 -> {error, timeout}
    end.

%% Listener that completes the handshake on one connection then stays
%% silent, holding the socket open until told to stop.
start_silent_listener() ->
    Parent = self(),
    Pid = spawn(fun() ->
        {ok, Listen} = gen_tcp:listen(0,
            [binary, {active, false}, {reuseaddr, true}, {packet, 0}]),
        {ok, Port} = inet:port(Listen),
        Parent ! {ready, Port},
        {ok, Sock} = gen_tcp:accept(Listen, 2000),
        {ok, _M, _P, Hdrs, _Rest} = read_request(Sock, <<>>, 2000),
        {ok, Info} = ws_h1_upgrade:validate_request(Hdrs),
        ok = gen_tcp:send(Sock, format_response(101,
                 ws_h1_upgrade:response_headers(Info))),
        receive stop -> gen_tcp:close(Sock) end
    end),
    Port = receive {ready, P} -> P after 2000 -> error(listener_not_ready) end,
    {Pid, Port}.

listener_loop(Listen, TestPid) ->
    case gen_tcp:accept(Listen, 500) of
        {ok, Sock} ->
            handle_accepted(Sock, TestPid),
            listener_loop(Listen, TestPid);
        {error, timeout} ->
            listener_loop(Listen, TestPid);
        {error, closed} ->
            ok
    end.

handle_accepted(Sock, TestPid) ->
    %% Transfer socket ownership to a dedicated handler process so the
    %% listener can loop back to accept the next connection.
    Handler = spawn(fun() ->
        receive {handle, S} -> serve(S, TestPid) end
    end),
    ok = gen_tcp:controlling_process(Sock, Handler),
    Handler ! {handle, Sock},
    ok.

serve(Sock, TestPid) ->
    case read_request(Sock, <<>>, 2000) of
        {ok, _Method, _Path, Hdrs, Rest} ->
            case ws_h1_upgrade:validate_request(Hdrs) of
                {ok, Info} ->
                    RespHdrs = ws_h1_upgrade:response_headers(Info),
                    Resp = format_response(101, RespHdrs),
                    ok = gen_tcp:send(Sock, Resp),
                    HandlerOpts = #{mode => echo, notify => TestPid},
                    case ws:accept(ws_transport_gen_tcp, Sock, #{},
                                   ws_test_handler, HandlerOpts) of
                        {ok, Pid} ->
                            case Rest of
                                <<>> -> ok;
                                _ -> Pid ! {tcp, Sock, Rest}
                            end;
                        _ -> gen_tcp:close(Sock)
                    end;
                _ ->
                    gen_tcp:close(Sock)
            end;
        _ ->
            gen_tcp:close(Sock)
    end.

format_response(Status, Hdrs) ->
    [<<"HTTP/1.1 ">>, integer_to_binary(Status), <<" Switching Protocols\r\n">>,
     [[N, <<": ">>, V, <<"\r\n">>] || {N, V} <- Hdrs],
     <<"\r\n">>].

read_request(Sock, Acc, Timeout) ->
    case gen_tcp:recv(Sock, 0, Timeout) of
        {ok, Bin} ->
            Acc2 = <<Acc/binary, Bin/binary>>,
            case erlang:decode_packet(http_bin, Acc2, []) of
                {more, _} -> read_request(Sock, Acc2, Timeout);
                {ok, {http_request, M, {abs_path, P}, _V}, R} ->
                    read_req_headers(Sock, R, M, P, [], Timeout);
                {ok, {http_request, M, P, _V}, R} ->
                    read_req_headers(Sock, R, M, P, [], Timeout);
                {ok, {http_error, _}, _} -> {error, bad_request};
                {error, Reason} -> {error, Reason}
            end;
        Err -> Err
    end.

read_req_headers(Sock, Buf, M, P, Acc, Timeout) ->
    case erlang:decode_packet(httph_bin, Buf, []) of
        {more, _} ->
            case gen_tcp:recv(Sock, 0, Timeout) of
                {ok, Bin} ->
                    read_req_headers(Sock, <<Buf/binary, Bin/binary>>, M, P, Acc, Timeout);
                Err -> Err
            end;
        {ok, http_eoh, Rest} ->
            {ok, M, P, lists:reverse(Acc), Rest};
        {ok, {http_header, _, N, _, V}, Rest} ->
            N2 = case N of
                _ when is_atom(N) -> atom_to_binary(N, utf8);
                _ -> N
            end,
            read_req_headers(Sock, Rest, M, P, [{N2, V} | Acc], Timeout);
        {error, R} -> {error, R}
    end.
