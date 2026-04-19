-module(ws_h1_upgrade_tests).
-include_lib("eunit/include/eunit.hrl").

%% Known-answer test from RFC 6455 §1.3.
accept_key_rfc_vector_test() ->
    ?assertEqual(<<"s3pPLMBiTxaQ9kYGzzhZRbK+xOo=">>,
                 ws_h1_upgrade:accept_key(<<"dGhlIHNhbXBsZSBub25jZQ==">>)).

good_request_headers() ->
    [{<<"Host">>, <<"example.com">>},
     {<<"Upgrade">>, <<"websocket">>},
     {<<"Connection">>, <<"Upgrade">>},
     {<<"Sec-WebSocket-Key">>, <<"dGhlIHNhbXBsZSBub25jZQ==">>},
     {<<"Sec-WebSocket-Version">>, <<"13">>}].

validate_request_ok_test() ->
    {ok, Info} = ws_h1_upgrade:validate_request(good_request_headers()),
    ?assertEqual(<<"s3pPLMBiTxaQ9kYGzzhZRbK+xOo=">>, maps:get(accept, Info)),
    ?assertEqual(<<"dGhlIHNhbXBsZSBub25jZQ==">>, maps:get(key, Info)),
    ?assertEqual(<<"13">>, maps:get(version, Info)),
    ?assertEqual([], maps:get(subprotocols, Info)),
    ?assertEqual([], maps:get(extensions, Info)).

validate_request_case_insensitive_headers_test() ->
    H = [{<<"host">>, <<"e">>},
         {<<"UPGRADE">>, <<"websocket">>},
         {<<"CoNnEcTiOn">>, <<"Upgrade">>},
         {<<"sec-websocket-key">>, <<"dGhlIHNhbXBsZSBub25jZQ==">>},
         {<<"sec-websocket-version">>, <<"13">>}],
    ?assertMatch({ok, _}, ws_h1_upgrade:validate_request(H)).

validate_request_accepts_map_test() ->
    M = #{<<"host">> => <<"x">>,
          <<"upgrade">> => <<"websocket">>,
          <<"connection">> => <<"keep-alive, Upgrade">>,
          <<"sec-websocket-key">> => <<"dGhlIHNhbXBsZSBub25jZQ==">>,
          <<"sec-websocket-version">> => <<"13">>},
    ?assertMatch({ok, _}, ws_h1_upgrade:validate_request(M)).

validate_request_missing_upgrade_test() ->
    Bad = lists:keydelete(<<"Upgrade">>, 1, good_request_headers()),
    ?assertMatch({error, missing_upgrade_header},
                 ws_h1_upgrade:validate_request(Bad)).

validate_request_wrong_upgrade_test() ->
    Bad = lists:keyreplace(<<"Upgrade">>, 1, good_request_headers(),
                           {<<"Upgrade">>, <<"h2c">>}),
    ?assertMatch({error, {invalid_upgrade, <<"h2c">>}},
                 ws_h1_upgrade:validate_request(Bad)).

validate_request_missing_connection_test() ->
    Bad = lists:keydelete(<<"Connection">>, 1, good_request_headers()),
    ?assertMatch({error, missing_connection_header},
                 ws_h1_upgrade:validate_request(Bad)).

validate_request_wrong_version_test() ->
    Bad = lists:keyreplace(<<"Sec-WebSocket-Version">>, 1, good_request_headers(),
                           {<<"Sec-WebSocket-Version">>, <<"8">>}),
    ?assertMatch({error, {unsupported_version, <<"8">>}},
                 ws_h1_upgrade:validate_request(Bad)).

validate_request_bad_key_length_test() ->
    Bad = lists:keyreplace(<<"Sec-WebSocket-Key">>, 1, good_request_headers(),
                           {<<"Sec-WebSocket-Key">>, <<"c2hvcnQ=">>}), %% 5 bytes
    ?assertMatch({error, bad_sec_websocket_key},
                 ws_h1_upgrade:validate_request(Bad)).

validate_request_subprotocols_test() ->
    H = [{<<"Sec-WebSocket-Protocol">>, <<"chat, superchat">>} | good_request_headers()],
    {ok, Info} = ws_h1_upgrade:validate_request(H),
    ?assertEqual([<<"chat">>, <<"superchat">>], maps:get(subprotocols, Info)).

validate_request_subprotocols_selection_test() ->
    H = [{<<"Sec-WebSocket-Protocol">>, <<"chat, superchat">>} | good_request_headers()],
    {ok, Info} = ws_h1_upgrade:validate_request(H,
                    #{required_subprotocols => [<<"superchat">>]}),
    ?assertEqual(<<"superchat">>, maps:get(selected_subprotocol, Info)).

validate_request_subprotocols_none_match_test() ->
    H = [{<<"Sec-WebSocket-Protocol">>, <<"chat">>} | good_request_headers()],
    ?assertMatch({error, no_acceptable_subprotocol},
        ws_h1_upgrade:validate_request(H, #{required_subprotocols => [<<"v2">>]})).

response_headers_basic_test() ->
    {ok, Info} = ws_h1_upgrade:validate_request(good_request_headers()),
    Hdrs = ws_h1_upgrade:response_headers(Info),
    ?assertEqual(<<"websocket">>, proplists:get_value(<<"upgrade">>, Hdrs)),
    ?assertEqual(<<"Upgrade">>, proplists:get_value(<<"connection">>, Hdrs)),
    ?assertEqual(<<"s3pPLMBiTxaQ9kYGzzhZRbK+xOo=">>,
                 proplists:get_value(<<"sec-websocket-accept">>, Hdrs)).

response_headers_with_subprotocol_test() ->
    H = [{<<"Sec-WebSocket-Protocol">>, <<"chat, v2">>} | good_request_headers()],
    {ok, Info} = ws_h1_upgrade:validate_request(H,
                    #{required_subprotocols => [<<"v2">>]}),
    Hdrs = ws_h1_upgrade:response_headers(Info),
    ?assertEqual(<<"v2">>, proplists:get_value(<<"sec-websocket-protocol">>, Hdrs)).

response_headers_with_extensions_test() ->
    {ok, Info} = ws_h1_upgrade:validate_request(good_request_headers()),
    Hdrs = ws_h1_upgrade:response_headers(Info,
              #{extensions => [<<"permessage-deflate">>]}),
    ?assertEqual(<<"permessage-deflate">>,
                 proplists:get_value(<<"sec-websocket-extensions">>, Hdrs)).

%% --- client side ------------------------------------------------------

client_key_is_16_byte_base64_test() ->
    K = ws_h1_upgrade:client_key(),
    ?assertEqual(16, byte_size(base64:decode(K))).

build_request_default_test() ->
    {Key, Hdrs} = ws_h1_upgrade:build_request(<<"example.com">>, 8080, <<"/ws">>),
    ?assertEqual(<<"example.com:8080">>, proplists:get_value(<<"host">>, Hdrs)),
    ?assertEqual(<<"websocket">>, proplists:get_value(<<"upgrade">>, Hdrs)),
    ?assertEqual(<<"Upgrade">>, proplists:get_value(<<"connection">>, Hdrs)),
    ?assertEqual(<<"13">>, proplists:get_value(<<"sec-websocket-version">>, Hdrs)),
    ?assertEqual(Key, proplists:get_value(<<"sec-websocket-key">>, Hdrs)).

build_request_subprotocols_test() ->
    {_, Hdrs} = ws_h1_upgrade:build_request(<<"e">>, 80, <<"/">>,
        #{subprotocols => [<<"chat">>, <<"v2">>]}),
    ?assertEqual(<<"chat, v2">>,
                 proplists:get_value(<<"sec-websocket-protocol">>, Hdrs)).

build_request_origin_test() ->
    {_, Hdrs} = ws_h1_upgrade:build_request(<<"e">>, 80, <<"/">>,
        #{origin => <<"https://example.com">>}),
    ?assertEqual(<<"https://example.com">>, proplists:get_value(<<"origin">>, Hdrs)).

validate_response_ok_test() ->
    Key = <<"dGhlIHNhbXBsZSBub25jZQ==">>,
    Accept = ws_h1_upgrade:accept_key(Key),
    RespHdrs = [{<<"Upgrade">>, <<"websocket">>},
                {<<"Connection">>, <<"Upgrade">>},
                {<<"Sec-WebSocket-Accept">>, Accept}],
    ?assertMatch({ok, #{accept := Accept}},
                 ws_h1_upgrade:validate_response(101, RespHdrs)).

validate_response_wrong_status_test() ->
    ?assertMatch({error, {unexpected_status, 200}},
                 ws_h1_upgrade:validate_response(200, [])).

validate_response_missing_accept_test() ->
    ?assertMatch({error, missing_sec_websocket_accept},
                 ws_h1_upgrade:validate_response(101,
                   [{<<"Upgrade">>, <<"websocket">>},
                    {<<"Connection">>, <<"Upgrade">>}])).

validate_response_with_subprotocol_test() ->
    Hdrs = [{<<"Upgrade">>, <<"websocket">>},
            {<<"Connection">>, <<"Upgrade">>},
            {<<"Sec-WebSocket-Accept">>, <<"x">>},
            {<<"Sec-WebSocket-Protocol">>, <<"chat">>}],
    ?assertMatch({ok, #{subprotocol := <<"chat">>}},
                 ws_h1_upgrade:validate_response(101, Hdrs)).
