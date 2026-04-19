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
         client_close_roundtrip/1]).

all() ->
    [client_handshake_and_echo,
     client_ping_gets_pong,
     client_close_roundtrip].

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
