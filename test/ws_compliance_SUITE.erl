%% @doc Autobahn WebSocket testsuite — compliance check.
%%
%% Docker-run Autobahn's `fuzzingclient' against a local CT-launched
%% echo server. Guarded behind `WS_RUN_AUTOBAHN=1' because it requires
%% docker and a 150 MB image pull. Without the flag the suite is
%% skipped so normal CI remains fast and offline.
%%
%% Invocation:
%%   WS_RUN_AUTOBAHN=1 rebar3 ct --suite=test/ws_compliance_SUITE
%%
%% Reports land under `_build/test/logs/autobahn/`.
-module(ws_compliance_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).

-export([autobahn_core_suites/1]).

-define(IMAGE, "crossbario/autobahn-testsuite").
-define(CASES, "1.*,2.*,3.*,4.*,5.*,6.*,7.*,9.*").

all() ->
    [autobahn_core_suites].

init_per_suite(Config) ->
    case os:getenv("WS_RUN_AUTOBAHN") of
        "1" ->
            case os:find_executable("docker") of
                false ->
                    {skip, "docker not found"};
                _ ->
                    {ok, _} = application:ensure_all_started(ws),
                    Config
            end;
        _ ->
            {skip, "set WS_RUN_AUTOBAHN=1 to run Autobahn compliance"}
    end.

end_per_suite(_Config) ->
    try application:stop(ws) catch _:_ -> ok end,
    ok.

autobahn_core_suites(Config) ->
    PrivDir = ?config(priv_dir, Config),
    ReportDir = filename:join(PrivDir, "autobahn"),
    ok = filelib:ensure_path(ReportDir),
    Spec = filename:join(ReportDir, "fuzzingclient.json"),
    {Listener, Port} = start_echo_server(),
    try
        ok = write_spec(Spec, Port, ReportDir),
        run_autobahn(Spec, ReportDir),
        assert_report_clean(ReportDir)
    after
        try exit(Listener, shutdown) catch _:_ -> ok end
    end.

%% ---------------------------------------------------------------------
%% Echo server: the same raw H1 upgrade listener as the other CT suites,
%% bound to 0.0.0.0 so the Autobahn container can reach it through
%% host.docker.internal (macOS/Windows) or a bind mount (Linux).

start_echo_server() ->
    Parent = self(),
    Pid = spawn(fun() ->
        {ok, Listen} = gen_tcp:listen(0,
            [binary, {active, false}, {reuseaddr, true},
             {packet, 0}, {ip, {0, 0, 0, 0}}]),
        {ok, Port} = inet:port(Listen),
        Parent ! {ready, Port},
        loop(Listen)
    end),
    Port = receive {ready, P} -> P after 2000 -> error(listener_not_ready) end,
    {Pid, Port}.

loop(Listen) ->
    case gen_tcp:accept(Listen, 500) of
        {ok, Sock} ->
            spawn_handler(Sock),
            loop(Listen);
        {error, timeout} -> loop(Listen);
        {error, closed} -> ok
    end.

spawn_handler(Sock) ->
    Handler = spawn(fun() ->
        receive {handle, S} -> serve(S) end
    end),
    ok = gen_tcp:controlling_process(Sock, Handler),
    Handler ! {handle, Sock},
    ok.

serve(Sock) ->
    case read_request(Sock, <<>>, 5000) of
        {ok, _M, _P, Hdrs, Rest} ->
            case ws_h1_upgrade:validate_request(Hdrs) of
                {ok, Info} ->
                    Resp = format_response(101, ws_h1_upgrade:response_headers(Info)),
                    ok = gen_tcp:send(Sock, Resp),
                    case ws:accept(ws_transport_gen_tcp, Sock, #{},
                                   ws_test_handler, #{mode => echo}) of
                        {ok, Pid} ->
                            case Rest of
                                <<>> -> ok;
                                _ -> Pid ! {tcp, Sock, Rest}
                            end;
                        _ -> gen_tcp:close(Sock)
                    end;
                _ -> gen_tcp:close(Sock)
            end;
        _ -> gen_tcp:close(Sock)
    end.

read_request(Sock, Acc, Timeout) ->
    case gen_tcp:recv(Sock, 0, Timeout) of
        {ok, Bin} ->
            Acc2 = <<Acc/binary, Bin/binary>>,
            case erlang:decode_packet(http_bin, Acc2, []) of
                {more, _} -> read_request(Sock, Acc2, Timeout);
                {ok, {http_request, M, {abs_path, P}, _V}, R} ->
                    read_headers(Sock, R, M, P, [], Timeout);
                {ok, {http_request, M, P, _V}, R} ->
                    read_headers(Sock, R, M, P, [], Timeout);
                {error, Reason} -> {error, Reason}
            end;
        Err -> Err
    end.

read_headers(Sock, Buf, M, P, Acc, Timeout) ->
    case erlang:decode_packet(httph_bin, Buf, []) of
        {more, _} ->
            case gen_tcp:recv(Sock, 0, Timeout) of
                {ok, B} -> read_headers(Sock, <<Buf/binary, B/binary>>, M, P, Acc, Timeout);
                Err -> Err
            end;
        {ok, http_eoh, Rest} -> {ok, M, P, lists:reverse(Acc), Rest};
        {ok, {http_header, _, N, _, V}, Rest} ->
            N2 = case N of
                _ when is_atom(N) -> atom_to_binary(N, utf8);
                _ -> N
            end,
            read_headers(Sock, Rest, M, P, [{N2, V} | Acc], Timeout);
        {error, R} -> {error, R}
    end.

format_response(Status, Hdrs) ->
    [<<"HTTP/1.1 ">>, integer_to_binary(Status), <<" Switching Protocols\r\n">>,
     [[N, <<": ">>, V, <<"\r\n">>] || {N, V} <- Hdrs],
     <<"\r\n">>].

%% ---------------------------------------------------------------------
%% Autobahn driver.

write_spec(SpecPath, Port, ReportDir) ->
    Host = case os:type() of
        {unix, darwin} -> "host.docker.internal";
        _ -> "host.docker.internal"
    end,
    Spec = iolist_to_binary([
        <<"{\n">>,
        <<"  \"outdir\": \"/reports\",\n">>,
        <<"  \"servers\": [{\n">>,
        <<"    \"agent\": \"erlang_ws\",\n">>,
        <<"    \"url\":   \"ws://">>, Host, <<":">>, integer_to_binary(Port), <<"/\"\n">>,
        <<"  }],\n">>,
        <<"  \"cases\":  [\"">>, re:replace(?CASES, ",", "\",\"", [global, {return, binary}]), <<"\"],\n">>,
        <<"  \"exclude-cases\": [],\n">>,
        <<"  \"exclude-agent-cases\": {}\n">>,
        <<"}\n">>
    ]),
    ok = file:write_file(SpecPath, Spec),
    _ = ReportDir,
    ok.

run_autobahn(SpecPath, ReportDir) ->
    SpecAbs = filename:absname(SpecPath),
    ReportAbs = filename:absname(ReportDir),
    Cmd = lists:flatten(io_lib:format(
        "docker run --rm "
        "-v ~s:/reports "
        "-v ~s:/fuzzingclient.json "
        "--add-host=host.docker.internal:host-gateway "
        "~s wstest -m fuzzingclient -s /fuzzingclient.json",
        [ReportAbs, SpecAbs, ?IMAGE])),
    ct:pal("Running: ~s", [Cmd]),
    Output = os:cmd(Cmd),
    ct:pal("Autobahn output:~n~s", [Output]),
    ok.

assert_report_clean(ReportDir) ->
    %% Autobahn writes a single index.json at the report root, keyed by
    %% agent name. Each case has `behavior` / `behaviorClose` fields;
    %% anything other than OK / INFORMATIONAL / NON-STRICT is a fail.
    IndexPath = filename:join(ReportDir, "index.json"),
    {ok, Bin} = file:read_file(IndexPath),
    %% Find all "behavior": "<word>" entries and classify.
    {match, Matches} = re:run(Bin,
        <<"\"behavior(?:Close)?\":\\s*\"([^\"]+)\"">>,
        [global, {capture, all_but_first, binary}]),
    Behaviors = [B || [B] <- Matches],
    Bad = [B || B <- Behaviors, not is_ok(B)],
    case Bad of
        [] -> ok;
        _ ->
            ct:pal("Autobahn failures: ~p~nindex.json at ~s", [Bad, IndexPath]),
            ?assertEqual([], Bad)
    end.

is_ok(<<"OK">>)            -> true;
is_ok(<<"INFORMATIONAL">>) -> true;
is_ok(<<"NON-STRICT">>)    -> true;
is_ok(<<"NO CLOSE">>)      -> true;
is_ok(_)                   -> false.
