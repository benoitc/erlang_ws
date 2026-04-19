-module(ws_h3_upgrade_tests).
-include_lib("eunit/include/eunit.hrl").

%% ws_h3_upgrade delegates to ws_h2_upgrade. These tests lock the
%% public surface so we notice if that delegation shape ever diverges
%% (for example once capsule-level helpers land).

good() ->
    [{<<":method">>,    <<"CONNECT">>},
     {<<":protocol">>,  <<"websocket">>},
     {<<":scheme">>,    <<"https">>},
     {<<":authority">>, <<"example.com">>},
     {<<":path">>,      <<"/chat">>}].

validate_request_ok_test() ->
    ?assertMatch({ok, #{protocol := <<"websocket">>}},
                 ws_h3_upgrade:validate_request(good())).

response_headers_status_200_test() ->
    {ok, Info} = ws_h3_upgrade:validate_request(good()),
    ?assertEqual(<<"200">>,
                 proplists:get_value(<<":status">>,
                                     ws_h3_upgrade:response_headers(Info))).

client_request_requires_connect_protocol_test() ->
    ?assertMatch({error, peer_does_not_allow_connect_protocol},
        ws_h3_upgrade:client_request(<<"https">>, <<"e">>, <<"/">>,
                                     #{peer_enable_connect_protocol => false})).

client_request_builds_connect_test() ->
    {ok, Hdrs} = ws_h3_upgrade:client_request(<<"https">>, <<"e">>, <<"/">>,
                    #{peer_enable_connect_protocol => true}),
    ?assertEqual(<<"CONNECT">>, proplists:get_value(<<":method">>, Hdrs)),
    ?assertEqual(<<"websocket">>, proplists:get_value(<<":protocol">>, Hdrs)).

validate_response_2xx_test() ->
    ?assertMatch({ok, _}, ws_h3_upgrade:validate_response(200, [])).
