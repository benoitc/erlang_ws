%% @doc End-to-end session tests over a gen_tcp loopback.
%%
%% We drive the server side through `ws:accept/5' on an accepted
%% `gen_tcp' socket, and the client side as a raw socket speaking
%% RFC 6455 bytes. This exercises `ws_frame' + `ws_session' +
%% `ws_transport_gen_tcp' together without requiring the client code
%% path (that is covered separately by `ws_client_SUITE').
-module(ws_session_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).

-export([echo_text/1,
         echo_binary/1,
         echo_large_binary/1,
         ping_gets_pong/1,
         orderly_client_close/1,
         server_initiated_close/1,
         fragmented_text/1,
         bad_utf8_text/1,
         oversize_frame/1,
         handler_info_send/1]).

all() ->
    [echo_text,
     echo_binary,
     echo_large_binary,
     ping_gets_pong,
     orderly_client_close,
     server_initiated_close,
     fragmented_text,
     bad_utf8_text,
     oversize_frame,
     handler_info_send].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(ws),
    Config.

end_per_suite(_Config) ->
    ok = application:stop(ws).

init_per_testcase(_TC, Config) ->
    {Server, Port} = start_listener(self()),
    [{listener, Server}, {port, Port} | Config].

end_per_testcase(_TC, Config) ->
    Pid = ?config(listener, Config),
    catch unlink(Pid),
    catch exit(Pid, shutdown),
    ok.

%% ---------------------------------------------------------------------
%% Test bodies

echo_text(Config) ->
    {ok, Sock} = connect(Config),
    send_frame(Sock, {text, <<"hello">>}),
    {text, <<"hello">>} = recv_frame(Sock),
    ok = gen_tcp:close(Sock).

echo_binary(Config) ->
    {ok, Sock} = connect(Config),
    send_frame(Sock, {binary, <<1, 2, 3, 4, 5>>}),
    {binary, <<1, 2, 3, 4, 5>>} = recv_frame(Sock),
    ok = gen_tcp:close(Sock).

echo_large_binary(Config) ->
    {ok, Sock} = connect(Config),
    Data = crypto:strong_rand_bytes(200000),
    send_frame(Sock, {binary, Data}),
    {binary, Got} = recv_frame(Sock),
    ?assertEqual(Data, Got),
    ok = gen_tcp:close(Sock).

ping_gets_pong(Config) ->
    {ok, Sock} = connect(Config),
    send_frame(Sock, {ping, <<"p">>}),
    {pong, <<"p">>} = recv_frame(Sock),
    ok = gen_tcp:close(Sock).

orderly_client_close(Config) ->
    {ok, Sock} = connect(Config),
    send_frame(Sock, {close, 1000, <<>>}),
    %% Server echoes a close frame.
    {close, 1000, <<>>} = recv_frame(Sock),
    ok = gen_tcp:close(Sock).

server_initiated_close(Config) ->
    {ok, Sock} = connect(Config),
    Pid = wait_for_session(),
    ws_session:close(Pid, 1000, <<"bye">>),
    {close, 1000, <<"bye">>} = recv_frame(Sock),
    %% Echo close back.
    send_frame(Sock, {close, 1000, <<>>}),
    ok = gen_tcp:close(Sock).

fragmented_text(Config) ->
    {ok, Sock} = connect(Config),
    %% opcode=text FIN=0 "he"
    MaskKey1 = 16#01020304,
    send_raw(Sock,
        <<0:1, 0:3, 1:4, 1:1, 2:7, MaskKey1:32,
          (ws_frame:mask(<<"he">>, MaskKey1))/binary>>),
    %% opcode=cont FIN=1 "llo"
    MaskKey2 = 16#0a0b0c0d,
    send_raw(Sock,
        <<1:1, 0:3, 0:4, 1:1, 3:7, MaskKey2:32,
          (ws_frame:mask(<<"llo">>, MaskKey2))/binary>>),
    {text, <<"hello">>} = recv_frame(Sock),
    ok = gen_tcp:close(Sock).

bad_utf8_text(Config) ->
    {ok, Sock} = connect(Config),
    MaskKey = 16#00000000,
    Bad = ws_frame:mask(<<16#F4, 16#90, 16#80, 16#80>>, MaskKey),
    send_raw(Sock, <<1:1, 0:3, 1:4, 1:1, 4:7, MaskKey:32, Bad/binary>>),
    %% Server must respond with a close frame code 1007 and close the socket.
    {close, 1007, _} = recv_frame(Sock),
    _ = recv_eof(Sock),
    ok.

oversize_frame(Config) ->
    %% Session is configured with max_frame=1024; a 2KB frame must be rejected.
    {ok, Sock} = connect_with(Config, #{parser_opts => #{max_frame => 1024}}),
    MaskKey = 0,
    Payload = binary:copy(<<"x">>, 2048),
    Masked = ws_frame:mask(Payload, MaskKey),
    send_raw(Sock,
        <<1:1, 0:3, 2:4, 1:1, 126:7, 2048:16, MaskKey:32, Masked/binary>>),
    {close, 1009, _} = recv_frame(Sock),
    _ = recv_eof(Sock),
    ok.

handler_info_send(Config) ->
    {ok, Sock} = connect(Config),
    Pid = wait_for_session(),
    Pid ! {send, {text, <<"from-info">>}},
    {text, <<"from-info">>} = recv_frame(Sock),
    ok = gen_tcp:close(Sock).

%% ---------------------------------------------------------------------
%% Helpers: raw listener that, for each accepted connection, spawns a
%% session wired to a `ws_test_handler' set to echo mode.

connect(Config) -> connect_with(Config, #{}).

connect_with(Config, SessionOpts) ->
    Port = ?config(port, Config),
    put(session_opts, SessionOpts),
    put(listener_feedback, self()),
    %% Re-send options to the listener via the session_opts test ETS hack:
    %% simpler: we restart the listener for custom opts.
    Pid = ?config(listener, Config),
    Pid ! {configure, SessionOpts, self()},
    receive configured -> ok after 1000 -> error(configure_timeout) end,
    {ok, Sock} = gen_tcp:connect({127,0,0,1}, Port, [binary, {active, false}, {packet, 0}]),
    {ok, Sock}.

send_raw(Sock, Data) ->
    ok = gen_tcp:send(Sock, iolist_to_binary(Data)).

send_frame(Sock, Frame) ->
    send_raw(Sock, ws_frame:encode(Frame, client)).

recv_frame(Sock) ->
    recv_frame(Sock, ws_frame:init_parser(#{role => client}), 2000).

recv_frame(Sock, Parser, Timeout) ->
    case gen_tcp:recv(Sock, 0, Timeout) of
        {ok, Bin} ->
            case ws_frame:parse(Parser, Bin) of
                {ok, [], P} -> recv_frame(Sock, P, Timeout);
                {ok, [Msg | _], _} -> Msg;
                {error, R, _} -> {error, R}
            end;
        {error, closed} ->
            {error, closed};
        Err -> Err
    end.

recv_eof(Sock) ->
    case gen_tcp:recv(Sock, 0, 1000) of
        {error, closed} -> ok;
        Other -> Other
    end.

wait_for_session() ->
    receive
        {ws_test_session, Pid} -> Pid
    after 2000 ->
        error(timeout_waiting_for_session)
    end.

start_listener(ParentPid) ->
    Parent = self(),
    Pid = spawn_link(fun() ->
        {ok, Listen} = gen_tcp:listen(0,
            [binary, {active, false}, {reuseaddr, true}, {packet, 0}]),
        {ok, Port} = inet:port(Listen),
        Parent ! {ready, Port},
        listener_loop(Listen, ParentPid, #{})
    end),
    Port = receive {ready, P} -> P after 2000 -> error(listener_not_ready) end,
    {Pid, Port}.

listener_loop(Listen, TestPid, Opts) ->
    %% Check for configure messages without blocking too long.
    Opts1 = receive
        {configure, NewOpts, From} ->
            From ! configured,
            NewOpts
    after 0 -> Opts
    end,
    case gen_tcp:accept(Listen, 200) of
        {ok, Sock} ->
            handle_accepted(Sock, TestPid, Opts1),
            listener_loop(Listen, TestPid, Opts1);
        {error, timeout} ->
            listener_loop(Listen, TestPid, Opts1);
        {error, closed} ->
            ok
    end.

handle_accepted(Sock, TestPid, Opts) ->
    TransportMod = ws_transport_gen_tcp,
    HandlerOpts = #{mode => echo, notify => TestPid},
    AcceptOpts = maps:with([parser_opts], Opts),
    case ws:accept(TransportMod, Sock, #{}, ws_test_handler,
                   HandlerOpts, AcceptOpts) of
        {ok, Pid} ->
            TestPid ! {ws_test_session, Pid};
        {error, Reason} ->
            TestPid ! {ws_test_error, Reason},
            gen_tcp:close(Sock)
    end.
