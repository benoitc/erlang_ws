%% @doc End-to-end tests covering the `examples/' modules and the
%% reference `ws_h1_tcp_server' used by the rest of the suite. Every
%% case boots a server on an OS-picked port, drives it with
%% `ws:connect/2', and tears everything down before the next case.
-module(ws_examples_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("public_key/include/public_key.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).

-export([echo_example_roundtrip/1,
         echo_client_helper/1,
         chat_broadcasts_to_other_clients/1,
         chat_sender_does_not_receive_own_message/1,
         many_concurrent_echo_clients/1,
         server_receives_fragmented_text/1,
         server_receives_frame_pipelined_with_handshake/1,
         client_sends_pings_and_gets_pongs/1,
         server_picks_matching_subprotocol/1,
         server_rejects_no_acceptable_subprotocol/1,
         tls_echo_roundtrip/1,
         large_message_roundtrip/1,
         server_closes_on_invalid_utf8/1]).

all() ->
    [echo_example_roundtrip,
     echo_client_helper,
     chat_broadcasts_to_other_clients,
     chat_sender_does_not_receive_own_message,
     many_concurrent_echo_clients,
     server_receives_fragmented_text,
     server_receives_frame_pipelined_with_handshake,
     client_sends_pings_and_gets_pongs,
     server_picks_matching_subprotocol,
     server_rejects_no_acceptable_subprotocol,
     tls_echo_roundtrip,
     large_message_roundtrip,
     server_closes_on_invalid_utf8].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(ws),
    %% Start `pg' in a dedicated owner process so the scope outlives
    %% the CT init process (init_per_suite would otherwise be linked
    %% to it and its scope would vanish between test cases).
    Parent = self(),
    Ref = make_ref(),
    Owner = spawn(fun() ->
        case pg:start_link() of
            {ok, _} -> Parent ! {Ref, ok};
            {error, {already_started, _}} -> Parent ! {Ref, ok};
            Other -> Parent ! {Ref, Other}
        end,
        receive stop -> ok end
    end),
    receive
        {Ref, ok} -> [{pg_owner, Owner} | Config];
        {Ref, Other} -> {skip, {pg_start_failed, Other}}
    after 1000 ->
        {skip, pg_start_timeout}
    end.

end_per_suite(Config) ->
    case proplists:get_value(pg_owner, Config) of
        Pid when is_pid(Pid) -> Pid ! stop;
        _ -> ok
    end,
    try application:stop(ws) catch _:_ -> ok end,
    ok.

init_per_testcase(_TC, Config) -> Config.
end_per_testcase(_TC, _Config) -> ok.

%% ---------------------------------------------------------------------
%% echo_server example

echo_example_roundtrip(_Config) ->
    {ok, Server} = ws_h1_tcp_server:start_link(
        #{handler => echo_server, handler_opts => #{}}),
    try
        {ok, P} = ws_h1_tcp_server:port(Server),
        {ok, Conn} = connect_client(P, #{}),
        ws:send(Conn, {text, <<"hello">>}),
        ?assertEqual({text, <<"hello">>}, wait_msg(1000)),
        ws:send(Conn, {binary, <<1,2,3>>}),
        ?assertEqual({binary, <<1,2,3>>}, wait_msg(1000)),
        ok = ws:close(Conn, 1000, <<>>)
    after
        ws_h1_tcp_server:stop(Server)
    end.

echo_client_helper(_Config) ->
    %% Boot the echo_server example, then call the echo_client helper
    %% which opens a fresh connection, sends, receives, closes.
    {ok, Server} = ws_h1_tcp_server:start_link(
        #{handler => echo_server, handler_opts => #{}}),
    try
        {ok, P} = ws_h1_tcp_server:port(Server),
        Url = url(P, <<"/">>),
        ?assertEqual({ok, <<"ping">>}, echo_client:send(Url, <<"ping">>)),
        ?assertEqual({ok, <<"again">>}, echo_client:send(Url, <<"again">>))
    after
        ws_h1_tcp_server:stop(Server)
    end.

%% ---------------------------------------------------------------------
%% chat_server example

chat_broadcasts_to_other_clients(_Config) ->
    {ok, Server} = ws_h1_tcp_server:start_link(
        #{handler => chat_server, handler_opts => #{}}),
    try
        {ok, P} = ws_h1_tcp_server:port(Server),
        {ok, A, RxA} = connect_named_client(P),
        {ok, B, RxB} = connect_named_client(P),
        {ok, C, RxC} = connect_named_client(P),
        %% Give the server init/2 time to pg:join for each of them.
        ok = wait_for_members(3, 1000),
        ws:send(A, {text, <<"hello">>}),
        ?assertEqual({text, <<"hello">>}, flush_one(RxB, 1000)),
        ?assertEqual({text, <<"hello">>}, flush_one(RxC, 1000)),
        %% Sender must not receive its own message.
        ?assertEqual(timeout, flush_one(RxA, 150)),
        [ws:close(X, 1000, <<>>) || X <- [A, B, C]]
    after
        ws_h1_tcp_server:stop(Server)
    end.

chat_sender_does_not_receive_own_message(_Config) ->
    {ok, Server} = ws_h1_tcp_server:start_link(
        #{handler => chat_server, handler_opts => #{}}),
    try
        {ok, P} = ws_h1_tcp_server:port(Server),
        {ok, A, RxA} = connect_named_client(P),
        ok = wait_for_members(1, 1000),
        ws:send(A, {text, <<"solo">>}),
        ?assertEqual(timeout, flush_one(RxA, 150)),
        ws:close(A, 1000, <<>>)
    after
        ws_h1_tcp_server:stop(Server)
    end.

wait_for_members(N, Deadline) when Deadline =< 0 ->
    case length(pg:get_members(chat_server_clients)) of
        N -> ok;
        _ -> {error, members_timeout}
    end;
wait_for_members(N, Deadline) ->
    case length(pg:get_members(chat_server_clients)) of
        N -> ok;
        _ ->
            timer:sleep(20),
            wait_for_members(N, Deadline - 20)
    end.

%% ---------------------------------------------------------------------
%% Scale

many_concurrent_echo_clients(_Config) ->
    {ok, Server} = ws_h1_tcp_server:start_link(
        #{handler => echo_server, handler_opts => #{}}),
    try
        {ok, P} = ws_h1_tcp_server:port(Server),
        N = 20,
        Parent = self(),
        Pids = [spawn_link(fun() ->
                                   {ok, Conn} = connect_client(P, #{}),
                                   Msg = iolist_to_binary(
                                           io_lib:format("c~b", [I])),
                                   ws:send(Conn, {text, Msg}),
                                   case wait_msg(2000) of
                                       {text, Msg} ->
                                           Parent ! {done, I};
                                       Other ->
                                           Parent ! {fail, I, Other}
                                   end,
                                   ws:close(Conn, 1000, <<>>)
                           end)
                || I <- lists:seq(1, N)],
        Results = [receive
                       {done, _} -> ok;
                       {fail, I, Other} -> {fail, I, Other}
                   end
                   || _ <- Pids],
        ?assert(lists:all(fun(R) -> R =:= ok end, Results))
    after
        ws_h1_tcp_server:stop(Server)
    end.

%% ---------------------------------------------------------------------
%% Wire-level server handling: exercised by crafting raw frames.

server_receives_fragmented_text(_Config) ->
    {ok, Server} = ws_h1_tcp_server:start_link(
        #{handler => echo_server, handler_opts => #{}}),
    try
        {ok, P} = ws_h1_tcp_server:port(Server),
        {ok, Sock} = raw_ws_connect(P, "/"),
        %% text fragment, FIN=0, 3 bytes
        K1 = 16#01020304,
        F1 = <<0:1, 0:3, 1:4, 1:1, 3:7, K1:32,
               (ws_frame:mask(<<"foo">>, K1))/binary>>,
        K2 = 16#05060708,
        F2 = <<1:1, 0:3, 0:4, 1:1, 3:7, K2:32,
               (ws_frame:mask(<<"bar">>, K2))/binary>>,
        ok = gen_tcp:send(Sock, F1),
        ok = gen_tcp:send(Sock, F2),
        ?assertEqual({text, <<"foobar">>}, recv_frame(Sock, 2000)),
        ok = gen_tcp:close(Sock)
    after
        ws_h1_tcp_server:stop(Server)
    end.

%% Mirror of the client-side coalescing case: a client that pipelines
%% its first frame with the upgrade request leaves those bytes in the
%% embedder's read buffer, past the end of the headers. They reach the
%% session as `initial_data', which the session drains before it arms
%% the socket.
%%
%% The second frame is what makes the ordering observable. It goes out
%% on its own write, so it is sitting in the receive buffer by the time
%% the session activates: handing the pipelined bytes over as a fake
%% socket message *after* activation lets this one overtake them, and
%% the echoes come back swapped.
server_receives_frame_pipelined_with_handshake(_Config) ->
    {ok, Server} = ws_h1_tcp_server:start_link(
        #{handler => echo_server, handler_opts => #{}}),
    try
        {ok, P} = ws_h1_tcp_server:port(Server),
        First = ws_frame:encode({text, <<"early">>}, client),
        {ok, Sock, Rest} = raw_ws_connect(P, "/", First),
        ok = gen_tcp:send(Sock, ws_frame:encode({text, <<"second">>},
                                                client)),
        P0 = ws_frame:init_parser(#{role => client}),
        {ok, Queued, P1} = ws_frame:parse(P0, Rest),
        {Msg1, S1} = recv_one(Sock, 2000, {Queued, P1}),
        {Msg2, _}  = recv_one(Sock, 2000, S1),
        ?assertEqual({text, <<"early">>}, Msg1),
        ?assertEqual({text, <<"second">>}, Msg2),
        ok = gen_tcp:close(Sock)
    after
        ws_h1_tcp_server:stop(Server)
    end.

client_sends_pings_and_gets_pongs(_Config) ->
    {ok, Server} = ws_h1_tcp_server:start_link(
        #{handler => echo_server, handler_opts => #{}}),
    try
        {ok, P} = ws_h1_tcp_server:port(Server),
        {ok, Sock} = raw_ws_connect(P, "/"),
        Send = fun(Frame) -> gen_tcp:send(Sock, ws_frame:encode(Frame, client)) end,
        ok = Send({ping, <<"1">>}),
        ok = Send({ping, <<"two">>}),
        ok = Send({ping, <<>>}),
        S0 = {[], ws_frame:init_parser(#{role => client})},
        {Msg1, S1} = recv_one(Sock, 1000, S0),
        {Msg2, S2} = recv_one(Sock, 1000, S1),
        {Msg3, _}  = recv_one(Sock, 1000, S2),
        ?assertEqual({pong, <<"1">>},   Msg1),
        ?assertEqual({pong, <<"two">>}, Msg2),
        ?assertEqual({pong, <<>>},      Msg3),
        ok = gen_tcp:close(Sock)
    after
        ws_h1_tcp_server:stop(Server)
    end.

server_picks_matching_subprotocol(_Config) ->
    {ok, Server} = ws_h1_tcp_server:start_link(
        #{handler => echo_server, handler_opts => #{},
          subprotocols => [<<"chat.v2">>, <<"chat">>]}),
    try
        {ok, P} = ws_h1_tcp_server:port(Server),
        %% Client offers chat and chat.v2. Server should pick chat.v2.
        TestPid = self(),
        {ok, Conn} = ws:connect(url(P, <<"/">>),
            #{handler => ws_examples_SUITE_subprotocol_probe,
              handler_opts => #{notify => TestPid},
              subprotocols => [<<"chat">>, <<"chat.v2">>]}),
        receive
            {subprotocol_info, Info} ->
                ?assertEqual(<<"chat.v2">>, maps:get(subprotocol, Info))
        after 1000 ->
            ct:fail(no_info)
        end,
        ok = ws:close(Conn, 1000, <<>>)
    after
        ws_h1_tcp_server:stop(Server)
    end.

server_rejects_no_acceptable_subprotocol(_Config) ->
    {ok, Server} = ws_h1_tcp_server:start_link(
        #{handler => echo_server, handler_opts => #{},
          subprotocols => [<<"only-v2">>]}),
    try
        {ok, P} = ws_h1_tcp_server:port(Server),
        Res = ws:connect(url(P, <<"/">>),
            #{handler => echo_client,
              handler_opts => #{notify => self()},
              subprotocols => [<<"chat">>]}),
        ?assertMatch({error, _}, Res)
    after
        ws_h1_tcp_server:stop(Server)
    end.

%% ---------------------------------------------------------------------
%% TLS (wss://)

tls_echo_roundtrip(Config) ->
    {Cert, Key} = self_signed_cert(Config),
    {ok, Server} = ws_h1_tcp_server:start_link(
        #{handler => echo_server, handler_opts => #{},
          tls => [{cert, Cert}, {key, Key}, {versions, ['tlsv1.3']}]}),
    try
        {ok, P} = ws_h1_tcp_server:port(Server),
        Url = iolist_to_binary(["wss://127.0.0.1:", integer_to_list(P), "/"]),
        {ok, Conn} = ws:connect(Url,
            #{handler => echo_client,
              handler_opts => #{notify => self()},
              ssl_opts => [{verify, verify_none},
                           {server_name_indication, "127.0.0.1"}]}),
        ws:send(Conn, {text, <<"over-tls">>}),
        ?assertEqual({echo, <<"over-tls">>}, wait_echo_msg(2000)),
        ok = ws:close(Conn, 1000, <<>>)
    after
        ws_h1_tcp_server:stop(Server)
    end.

large_message_roundtrip(_Config) ->
    {ok, Server} = ws_h1_tcp_server:start_link(
        #{handler => echo_server, handler_opts => #{}}),
    try
        {ok, P} = ws_h1_tcp_server:port(Server),
        {ok, Conn} = connect_client(P, #{}),
        Data = crypto:strong_rand_bytes(512 * 1024),
        ws:send(Conn, {binary, Data}),
        ?assertEqual({binary, Data}, wait_msg(5000)),
        ok = ws:close(Conn, 1000, <<>>)
    after
        ws_h1_tcp_server:stop(Server)
    end.

server_closes_on_invalid_utf8(_Config) ->
    {ok, Server} = ws_h1_tcp_server:start_link(
        #{handler => echo_server, handler_opts => #{}}),
    try
        {ok, P} = ws_h1_tcp_server:port(Server),
        {ok, Sock} = raw_ws_connect(P, "/"),
        MaskKey = 0,
        BadBin = <<16#F4, 16#90, 16#80, 16#80>>,
        ok = gen_tcp:send(Sock, <<1:1, 0:3, 1:4, 1:1, 4:7, MaskKey:32,
                                  (ws_frame:mask(BadBin, MaskKey))/binary>>),
        {close, 1007, _} = recv_frame(Sock, 1000),
        {error, closed} = gen_tcp:recv(Sock, 0, 1000),
        ok
    after
        ws_h1_tcp_server:stop(Server)
    end.

%% ---------------------------------------------------------------------
%% helpers

url(Port, Path) ->
    iolist_to_binary(["ws://127.0.0.1:", integer_to_list(Port), Path]).

connect_client(Port, Extra) ->
    ws:connect(url(Port, <<"/">>),
        maps:merge(#{handler => ws_examples_SUITE_forwarder,
                     handler_opts => #{notify => self()}}, Extra)).

connect_named_client(Port) ->
    {ok, Conn} = connect_client(Port, #{}),
    %% Return {ok, Conn, StreamRef}. The StreamRef is a unique tag we
    %% pass to the handler so messages can be demultiplexed by caller
    %% (each handler gets a fresh notify PID = a small relay).
    {ok, Conn, self()}.

wait_msg(Timeout) ->
    receive
        {ws_forward, Msg} -> Msg
    after Timeout -> error(timeout)
    end.

wait_echo_msg(Timeout) ->
    receive
        {echo, _} = M -> M
    after Timeout -> error(timeout)
    end.

%% flush_one drains ONE ws_forward message (tagged with a monotonic
%% counter for multi-connection tests). Returns `timeout' rather than
%% erroring so tests can assert "no message was received".
flush_one(_RxMarker, Timeout) ->
    receive
        {ws_forward, Msg} -> Msg
    after Timeout -> timeout
    end.

raw_ws_connect(Port, Path) ->
    {ok, Sock, _Rest} = raw_ws_connect(Port, Path, <<>>),
    {ok, Sock}.

%% `Trailer' rides in the same write as the upgrade request, so the
%% server reads it past the end of the headers. Returns the bytes that
%% followed the 101 in the client's own recv; the caller must seed its
%% parser with them or a fast reply can be lost.
raw_ws_connect(Port, Path, Trailer) ->
    {ok, Sock} = gen_tcp:connect({127,0,0,1}, Port,
        [binary, {active, false}, {packet, 0}]),
    Key = ws_h1_upgrade:client_key(),
    Req = [<<"GET ">>, Path, <<" HTTP/1.1\r\n",
            "Host: 127.0.0.1:">>, integer_to_binary(Port), <<"\r\n",
            "Upgrade: websocket\r\n",
            "Connection: Upgrade\r\n",
            "Sec-WebSocket-Key: ">>, Key, <<"\r\n",
            "Sec-WebSocket-Version: 13\r\n\r\n">>, Trailer],
    ok = gen_tcp:send(Sock, Req),
    {ok, Rest} = read_101(Sock, <<>>, 2000),
    {ok, Sock, Rest}.

read_101(Sock, Acc, Timeout) ->
    case erlang:decode_packet(http_bin, Acc, []) of
        {more, _} ->
            {ok, Bin} = gen_tcp:recv(Sock, 0, Timeout),
            read_101(Sock, <<Acc/binary, Bin/binary>>, Timeout);
        {ok, {http_response, _V, 101, _R}, R} ->
            skip_headers(Sock, R, Timeout);
        {ok, _, _} ->
            {error, unexpected_response}
    end.

skip_headers(Sock, Buf, Timeout) ->
    case erlang:decode_packet(httph_bin, Buf, []) of
        {more, _} ->
            {ok, Bin} = gen_tcp:recv(Sock, 0, Timeout),
            skip_headers(Sock, <<Buf/binary, Bin/binary>>, Timeout);
        {ok, http_eoh, Rest} -> {ok, Rest};
        {ok, {http_header, _, _, _, _}, Rest} -> skip_headers(Sock, Rest, Timeout)
    end.

recv_frame(Sock, Timeout) ->
    recv_frame(Sock, Timeout, <<>>).

%% `Seed' is bytes already read off the socket (e.g. trailing the 101).
recv_frame(Sock, Timeout, Seed) ->
    P0 = ws_frame:init_parser(#{role => client}),
    {ok, Queued, P1} = ws_frame:parse(P0, Seed),
    {Msg, _} = recv_one(Sock, Timeout, {Queued, P1}),
    Msg.

%% State is `{QueuedMessages, ParserState}`. Multi-frame recv'es fill
%% the queue; subsequent calls drain it before touching the socket.
recv_one(_Sock, _Timeout, {[M | Rest], P}) ->
    {M, {Rest, P}};
recv_one(Sock, Timeout, {[], P}) ->
    case gen_tcp:recv(Sock, 0, Timeout) of
        {ok, Bin} ->
            case ws_frame:parse(P, Bin) of
                {ok, [], P2} -> recv_one(Sock, Timeout, {[], P2});
                {ok, [M | Rest], P2} -> {M, {Rest, P2}};
                {error, R, _} -> {{error, R}, {[], P}}
            end;
        Err -> {Err, {[], P}}
    end.

%% --- self-signed cert for TLS tests ----------------------------------

self_signed_cert(Config) ->
    DataDir = ?config(priv_dir, Config),
    Key = public_key:generate_key({rsa, 2048, 65537}),
    #'RSAPrivateKey'{} = Key,
    KeyDer = public_key:der_encode('RSAPrivateKey', Key),
    %% Build a self-signed cert via OpenSSL (reliable across OTP).
    KeyPath = filename:join(DataDir, "key.pem"),
    CertPath = filename:join(DataDir, "cert.pem"),
    ok = file:write_file(KeyPath, public_key:pem_encode(
            [public_key:pem_entry_encode('RSAPrivateKey', Key)])),
    Cmd = lists:flatten(io_lib:format(
        "openssl req -new -x509 -key ~s -out ~s -days 1 "
        "-subj '/CN=127.0.0.1' >/dev/null 2>&1",
        [KeyPath, CertPath])),
    case os:cmd(Cmd) of
        "" -> ok;
        _  -> ok
    end,
    {ok, CertPem} = file:read_file(CertPath),
    [{'Certificate', CertDer, _}] = public_key:pem_decode(CertPem),
    {CertDer, {'RSAPrivateKey', KeyDer}}.
