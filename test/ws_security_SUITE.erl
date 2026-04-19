%% @doc Targeted hardening tests.
%%
%% Every case here corresponds to a finding from the internal review
%% that led to the 0.1.x hardening pass. Each proves that the library
%% handles the adversarial case gracefully — typed error, no crash,
%% no unbounded resource growth.
-module(ws_security_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).

-export([malformed_base64_key_is_typed_error/1,
         sec_websocket_key_wrong_length_is_typed_error/1,
         server_bounds_pre_upgrade_read/1,
         server_rejects_garbage_before_request/1,
         deflate_bomb_is_capped/1,
         deflate_honours_max_size_option/1,
         deflate_allows_large_under_cap/1,
         close_code_1004_1005_1006_1015_rejected/1,
         send_during_closing_is_noop/1,
         handler_init_stop_closes_session/1,
         send_list_preserves_order/1]).

all() ->
    [malformed_base64_key_is_typed_error,
     sec_websocket_key_wrong_length_is_typed_error,
     server_bounds_pre_upgrade_read,
     server_rejects_garbage_before_request,
     deflate_bomb_is_capped,
     deflate_honours_max_size_option,
     deflate_allows_large_under_cap,
     close_code_1004_1005_1006_1015_rejected,
     send_during_closing_is_noop,
     handler_init_stop_closes_session,
     send_list_preserves_order].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(ws),
    Config.

end_per_suite(_Config) ->
    catch application:stop(ws),
    ok.

%% ---------------------------------------------------------------------
%% Handshake input validation

good_request() ->
    [{<<"Host">>, <<"example.com">>},
     {<<"Upgrade">>, <<"websocket">>},
     {<<"Connection">>, <<"Upgrade">>},
     {<<"Sec-WebSocket-Key">>, <<"dGhlIHNhbXBsZSBub25jZQ==">>},
     {<<"Sec-WebSocket-Version">>, <<"13">>}].

malformed_base64_key_is_typed_error(_Config) ->
    Bad = lists:keyreplace(<<"Sec-WebSocket-Key">>, 1, good_request(),
                           {<<"Sec-WebSocket-Key">>, <<"not!valid!base64!">>}),
    ?assertMatch({error, bad_sec_websocket_key},
                 ws_h1_upgrade:validate_request(Bad)).

sec_websocket_key_wrong_length_is_typed_error(_Config) ->
    %% 12 bytes once base64-decoded (16 bytes is required).
    Short = base64:encode(<<"twelve-bytes">>),
    Bad = lists:keyreplace(<<"Sec-WebSocket-Key">>, 1, good_request(),
                           {<<"Sec-WebSocket-Key">>, Short}),
    ?assertMatch({error, bad_sec_websocket_key},
                 ws_h1_upgrade:validate_request(Bad)).

%% ---------------------------------------------------------------------
%% Server-side pre-upgrade read bound

server_bounds_pre_upgrade_read(_Config) ->
    {ok, Server} = ws_h1_tcp_server:start_link(
        #{handler => echo_server, handler_opts => #{},
          max_handshake_size => 256}),
    try
        {ok, Port} = ws_h1_tcp_server:port(Server),
        {ok, Sock} = gen_tcp:connect({127,0,0,1}, Port,
            [binary, {active, false}]),
        %% Send a valid request line followed by >256 bytes of junk
        %% headers — the server must close the socket before we cross
        %% the full handshake.
        Junk = binary:copy(<<"X-Big: filler\r\n">>, 100),
        Prefix = <<"GET / HTTP/1.1\r\nHost: x\r\n">>,
        ok = gen_tcp:send(Sock, <<Prefix/binary, Junk/binary>>),
        {error, closed} = drain(Sock, 2000),
        ok
    after
        ws_h1_tcp_server:stop(Server)
    end.

server_rejects_garbage_before_request(_Config) ->
    {ok, Server} = ws_h1_tcp_server:start_link(
        #{handler => echo_server, handler_opts => #{}}),
    try
        {ok, Port} = ws_h1_tcp_server:port(Server),
        {ok, Sock} = gen_tcp:connect({127,0,0,1}, Port,
            [binary, {active, false}]),
        ok = gen_tcp:send(Sock, <<"\x00\x01\x02\x03\r\nGET">>),
        {error, closed} = drain(Sock, 2000),
        ok
    after
        ws_h1_tcp_server:stop(Server)
    end.

drain(Sock, Timeout) ->
    case gen_tcp:recv(Sock, 0, Timeout) of
        {ok, _} -> drain(Sock, Timeout);
        {error, _} = E -> E
    end.

%% ---------------------------------------------------------------------
%% Deflate bomb protection

deflate_bomb_is_capped(_Config) ->
    %% Build a zero-filled 1 MiB payload, deflate it (compresses to a
    %% few hundred bytes), then inflate with a 64 KiB cap. It must
    %% return {error, {inflate_too_big, _}}, not allocate 1 MiB.
    Z = zlib:open(),
    ok = zlib:deflateInit(Z, default, deflated, -15, 8, default),
    Data = binary:copy(<<0>>, 1024 * 1024),
    Compressed = iolist_to_binary(zlib:deflate(Z, Data, sync)),
    Len = byte_size(Compressed) - 4,
    <<Body:Len/binary, 0:8, 0:8, 255:8, 255:8>> = Compressed,
    zlib:close(Z),

    N = #{server_context_takeover => takeover,
          client_context_takeover => takeover,
          server_max_window_bits  => 15,
          client_max_window_bits  => 15},
    I = ws_deflate:init_inflate(N, client),
    try
        ?assertMatch({error, {inflate_too_big, 65536}},
                     ws_deflate:inflate(I, takeover, Body, 65536))
    after
        zlib:close(I)
    end.

deflate_honours_max_size_option(_Config) ->
    %% Same deflated payload, infinity cap — round-trip succeeds.
    Z = zlib:open(),
    ok = zlib:deflateInit(Z, default, deflated, -15, 8, default),
    Data = binary:copy(<<0>>, 10000),
    Compressed = iolist_to_binary(zlib:deflate(Z, Data, sync)),
    Len = byte_size(Compressed) - 4,
    <<Body:Len/binary, 0:8, 0:8, 255:8, 255:8>> = Compressed,
    zlib:close(Z),

    N = #{server_context_takeover => takeover,
          client_context_takeover => takeover,
          server_max_window_bits  => 15,
          client_max_window_bits  => 15},
    I = ws_deflate:init_inflate(N, client),
    try
        ?assertEqual({ok, Data},
                     ws_deflate:inflate(I, takeover, Body, infinity))
    after
        zlib:close(I)
    end.

deflate_allows_large_under_cap(_Config) ->
    %% Under the default 64 MiB cap.
    N = #{server_context_takeover => takeover,
          client_context_takeover => takeover,
          server_max_window_bits  => 15,
          client_max_window_bits  => 15},
    D = ws_deflate:init_deflate(N, server),
    I = ws_deflate:init_inflate(N, client),
    try
        Data = crypto:strong_rand_bytes(32 * 1024),
        Wire = ws_deflate:deflate(D, takeover, Data),
        ?assertEqual({ok, Data},
                     ws_deflate:inflate(I, takeover, Wire))
    after
        zlib:close(D), zlib:close(I)
    end.

%% ---------------------------------------------------------------------
%% Close-code validation edge cases

close_code_1004_1005_1006_1015_rejected(_Config) ->
    [?assertNot(ws_close:valid_on_wire(C)) || C <- [1004, 1005, 1006, 1015]],
    [?assert(ws_close:valid_on_wire(C))
     || C <- [1000, 1001, 1002, 1003, 1007, 1008, 1009, 1010, 1011,
              3000, 4999]].

%% ---------------------------------------------------------------------
%% Session state invariants

send_during_closing_is_noop(_Config) ->
    {ok, Server} = ws_h1_tcp_server:start_link(
        #{handler => echo_server, handler_opts => #{}}),
    try
        {ok, Port} = ws_h1_tcp_server:port(Server),
        {ok, Conn} = ws:connect(url(Port),
            #{handler => snippet_client_relay,
              handler_opts => #{notify => self()}}),
        MRef = erlang:monitor(process, Conn),
        ws:close(Conn, 1000, <<>>),
        %% After close initiated, further sends must not crash.
        ws:send(Conn, {text, <<"after-close">>}),
        ws:send(Conn, {binary, <<0,1,2>>}),
        receive {'DOWN', MRef, process, Conn, _} -> ok
        after 2000 -> ct:fail(session_did_not_exit)
        end
    after
        ws_h1_tcp_server:stop(Server)
    end.

handler_init_stop_closes_session(_Config) ->
    {ok, Server} = ws_h1_tcp_server:start_link(
        #{handler => stop_on_init_handler, handler_opts => #{}}),
    try
        {ok, Port} = ws_h1_tcp_server:port(Server),
        %% Client does complete the handshake — the server's handler
        %% returns {stop, ...} from init/2, which aborts the session.
        %% The client observes the peer-side close shortly after.
        Res = ws:connect(url(Port),
            #{handler => snippet_client_relay,
              handler_opts => #{notify => self()}}),
        case Res of
            {ok, Conn} ->
                MRef = erlang:monitor(process, Conn),
                receive {'DOWN', MRef, process, Conn, _} -> ok
                after 2000 -> ct:fail(client_hanging)
                end;
            {error, _} -> ok
        end
    after
        ws_h1_tcp_server:stop(Server)
    end.

send_list_preserves_order(_Config) ->
    {ok, Server} = ws_h1_tcp_server:start_link(
        #{handler => echo_server, handler_opts => #{}}),
    try
        {ok, Port} = ws_h1_tcp_server:port(Server),
        {ok, Conn} = ws:connect(url(Port),
            #{handler => snippet_client_relay,
              handler_opts => #{notify => self()}}),
        Msgs = [{text, iolist_to_binary([<<"m">>, integer_to_binary(I)])}
                || I <- lists:seq(1, 10)],
        ws:send(Conn, Msgs),
        Got = collect(10, 2000, []),
        ?assertEqual(Msgs, Got),
        ws:close(Conn, 1000, <<>>)
    after
        ws_h1_tcp_server:stop(Server)
    end.

collect(0, _, Acc) -> lists:reverse(Acc);
collect(N, Timeout, Acc) ->
    receive
        {ws, F} -> collect(N - 1, Timeout, [F | Acc])
    after Timeout ->
        error({timeout, N, lists:reverse(Acc)})
    end.

url(Port) ->
    iolist_to_binary(["ws://127.0.0.1:", integer_to_list(Port), "/"]).
