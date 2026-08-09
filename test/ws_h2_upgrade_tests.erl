-module(ws_h2_upgrade_tests).
-include_lib("eunit/include/eunit.hrl").

good() ->
    [{<<":method">>,    <<"CONNECT">>},
     {<<":protocol">>,  <<"websocket">>},
     {<<":scheme">>,    <<"https">>},
     {<<":authority">>, <<"example.com">>},
     {<<":path">>,      <<"/chat">>},
     {<<"sec-websocket-version">>, <<"13">>}].

validate_request_ok_test() ->
    {ok, Info} = ws_h2_upgrade:validate_request(good()),
    ?assertEqual(<<"CONNECT">>, maps:get(method, Info)),
    ?assertEqual(<<"websocket">>, maps:get(protocol, Info)),
    ?assertEqual(<<"/chat">>, maps:get(path, Info)),
    ?assertEqual(<<"13">>, maps:get(version, Info)).

validate_request_accepts_map_test() ->
    M = maps:from_list(good()),
    ?assertMatch({ok, _}, ws_h2_upgrade:validate_request(M)).

validate_request_wrong_method_test() ->
    Bad = lists:keyreplace(<<":method">>, 1, good(),
                           {<<":method">>, <<"GET">>}),
    ?assertMatch({error, wrong_method}, ws_h2_upgrade:validate_request(Bad)).

validate_request_wrong_protocol_test() ->
    Bad = lists:keyreplace(<<":protocol">>, 1, good(),
                           {<<":protocol">>, <<"webtransport">>}),
    ?assertMatch({error, wrong_protocol}, ws_h2_upgrade:validate_request(Bad)).

validate_request_missing_scheme_test() ->
    Bad = lists:keydelete(<<":scheme">>, 1, good()),
    ?assertMatch({error, missing_scheme}, ws_h2_upgrade:validate_request(Bad)).

validate_request_missing_authority_test() ->
    Bad = lists:keydelete(<<":authority">>, 1, good()),
    ?assertMatch({error, missing_authority}, ws_h2_upgrade:validate_request(Bad)).

validate_request_missing_path_test() ->
    Bad = lists:keydelete(<<":path">>, 1, good()),
    ?assertMatch({error, missing_path}, ws_h2_upgrade:validate_request(Bad)).

%% RFC 8441 section 5 keeps Sec-WebSocket-Version from RFC 6455, so an
%% extended CONNECT without it is as bad as an H1 upgrade without it.
validate_request_missing_version_test() ->
    Bad = lists:keydelete(<<"sec-websocket-version">>, 1, good()),
    ?assertMatch({error, {unsupported_version, undefined}},
                 ws_h2_upgrade:validate_request(Bad)).

validate_request_wrong_version_test() ->
    Bad = lists:keyreplace(<<"sec-websocket-version">>, 1, good(),
                           {<<"sec-websocket-version">>, <<"8">>}),
    ?assertMatch({error, {unsupported_version, <<"8">>}},
                 ws_h2_upgrade:validate_request(Bad)).

%% A stream that is not extended CONNECT at all reports that first,
%% rather than blaming the version header.
validate_request_pseudo_headers_checked_before_version_test() ->
    Bad = lists:keydelete(<<"sec-websocket-version">>, 1,
            lists:keyreplace(<<":method">>, 1, good(),
                             {<<":method">>, <<"GET">>})),
    ?assertMatch({error, wrong_method}, ws_h2_upgrade:validate_request(Bad)).

validate_request_subprotocols_test() ->
    H = [{<<"sec-websocket-protocol">>, <<"chat, v2">>} | good()],
    {ok, Info} = ws_h2_upgrade:validate_request(H),
    ?assertEqual([<<"chat">>, <<"v2">>], maps:get(subprotocols, Info)).

validate_request_subprotocol_selection_test() ->
    H = [{<<"sec-websocket-protocol">>, <<"chat, v2">>} | good()],
    {ok, Info} = ws_h2_upgrade:validate_request(H,
                    #{required_subprotocols => [<<"v2">>]}),
    ?assertEqual(<<"v2">>, maps:get(selected_subprotocol, Info)).

validate_request_no_matching_subprotocol_test() ->
    H = [{<<"sec-websocket-protocol">>, <<"chat">>} | good()],
    ?assertMatch({error, no_acceptable_subprotocol},
        ws_h2_upgrade:validate_request(H, #{required_subprotocols => [<<"v2">>]})).

response_headers_basic_test() ->
    {ok, Info} = ws_h2_upgrade:validate_request(good()),
    Hdrs = ws_h2_upgrade:response_headers(Info),
    ?assertEqual(<<"200">>, proplists:get_value(<<":status">>, Hdrs)).

response_headers_with_subprotocol_test() ->
    H = [{<<"sec-websocket-protocol">>, <<"chat">>} | good()],
    {ok, Info} = ws_h2_upgrade:validate_request(H,
                    #{required_subprotocols => [<<"chat">>]}),
    Hdrs = ws_h2_upgrade:response_headers(Info),
    ?assertEqual(<<"chat">>,
                 proplists:get_value(<<"sec-websocket-protocol">>, Hdrs)).

%% --- client --------------------------------------------------------------

client_request_requires_peer_connect_protocol_test() ->
    Opts = #{peer_enable_connect_protocol => false},
    ?assertMatch({error, peer_does_not_allow_connect_protocol},
        ws_h2_upgrade:client_request(<<"https">>, <<"e">>, <<"/">>, Opts)).

client_request_builds_pseudo_headers_test() ->
    Opts = #{peer_enable_connect_protocol => true,
             subprotocols => [<<"chat">>]},
    {ok, Hdrs} = ws_h2_upgrade:client_request(<<"https">>, <<"e">>, <<"/ws">>, Opts),
    ?assertEqual(<<"CONNECT">>,   proplists:get_value(<<":method">>, Hdrs)),
    ?assertEqual(<<"websocket">>, proplists:get_value(<<":protocol">>, Hdrs)),
    ?assertEqual(<<"https">>,     proplists:get_value(<<":scheme">>, Hdrs)),
    ?assertEqual(<<"e">>,         proplists:get_value(<<":authority">>, Hdrs)),
    ?assertEqual(<<"/ws">>,       proplists:get_value(<<":path">>, Hdrs)),
    ?assertEqual(<<"13">>,
                 proplists:get_value(<<"sec-websocket-version">>, Hdrs)),
    ?assertEqual(<<"chat">>,
                 proplists:get_value(<<"sec-websocket-protocol">>, Hdrs)).

%% What we send must be what we accept.
client_request_round_trips_through_validate_test() ->
    Opts = #{peer_enable_connect_protocol => true},
    {ok, Hdrs} = ws_h2_upgrade:client_request(<<"https">>, <<"e">>, <<"/ws">>,
                                              Opts),
    ?assertMatch({ok, _}, ws_h2_upgrade:validate_request(Hdrs)).

validate_response_accepts_2xx_test() ->
    ?assertMatch({ok, _}, ws_h2_upgrade:validate_response(200, [])),
    ?assertMatch({ok, _}, ws_h2_upgrade:validate_response(204, [])).

validate_response_rejects_non_2xx_test() ->
    ?assertMatch({error, {unexpected_status, 404}},
                 ws_h2_upgrade:validate_response(404, [])),
    ?assertMatch({error, {unexpected_status, 500}},
                 ws_h2_upgrade:validate_response(500, [])).

validate_response_surfaces_subprotocol_test() ->
    ?assertMatch({ok, #{subprotocol := <<"chat">>}},
                 ws_h2_upgrade:validate_response(200,
                   [{<<"sec-websocket-protocol">>, <<"chat">>}])).
