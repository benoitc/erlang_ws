-module(ws_deflate_tests).
-include_lib("eunit/include/eunit.hrl").

negotiate_defaults_test() ->
    {ok, IoList, Neg} = ws_deflate:negotiate_server([], #{}),
    ?assertEqual(<<"permessage-deflate">>, iolist_to_binary(IoList)),
    ?assertEqual(takeover, maps:get(server_context_takeover, Neg)),
    ?assertEqual(takeover, maps:get(client_context_takeover, Neg)),
    ?assertEqual(15, maps:get(server_max_window_bits, Neg)),
    ?assertEqual(15, maps:get(client_max_window_bits, Neg)).

negotiate_server_no_takeover_test() ->
    {ok, IoList, Neg} = ws_deflate:negotiate_server([],
        #{server_context_takeover => no_takeover}),
    Bin = iolist_to_binary(IoList),
    ?assertEqual(no_takeover, maps:get(server_context_takeover, Neg)),
    ?assertMatch({_, _},
                 binary:match(Bin, <<"server_no_context_takeover">>)).

negotiate_client_request_window_bits_test() ->
    {ok, IoList, Neg} = ws_deflate:negotiate_server(
        [{<<"server_max_window_bits">>, <<"12">>}], #{}),
    ?assertEqual(12, maps:get(server_max_window_bits, Neg)),
    Bin = iolist_to_binary(IoList),
    ?assertMatch({_, _}, binary:match(Bin, <<"server_max_window_bits=12">>)).

negotiate_ignores_duplicates_test() ->
    Params = [<<"client_max_window_bits">>, <<"client_max_window_bits">>],
    ?assertEqual(ignore, ws_deflate:negotiate_server(Params, #{})).

negotiate_ignores_unknown_param_test() ->
    ?assertEqual(ignore, ws_deflate:negotiate_server(
        [{<<"bogus">>, <<"v">>}], #{})).

client_offer_default_test() ->
    Offer = iolist_to_binary(ws_deflate:client_offer(#{})),
    ?assertMatch({_, _}, binary:match(Offer, <<"permessage-deflate">>)),
    ?assertMatch({_, _}, binary:match(Offer, <<"client_max_window_bits">>)).

client_offer_no_takeover_test() ->
    Offer = iolist_to_binary(ws_deflate:client_offer(
        #{client_context_takeover => no_takeover,
          server_context_takeover => no_takeover})),
    ?assertMatch({_, _}, binary:match(Offer, <<"client_no_context_takeover">>)),
    ?assertMatch({_, _}, binary:match(Offer, <<"server_no_context_takeover">>)).

parse_server_response_defaults_test() ->
    {ok, N} = ws_deflate:parse_server_response([]),
    ?assertEqual(takeover, maps:get(server_context_takeover, N)),
    ?assertEqual(15, maps:get(server_max_window_bits, N)).

parse_server_response_bits_test() ->
    {ok, N} = ws_deflate:parse_server_response(
        [{<<"server_max_window_bits">>, <<"10">>}]),
    ?assertEqual(10, maps:get(server_max_window_bits, N)).

parse_server_response_unknown_test() ->
    ?assertMatch({error, unknown_param},
                 ws_deflate:parse_server_response([{<<"x">>, <<"1">>}])).

%% Full round-trip: compress and decompress on the same side using the
%% negotiated parameters. This mirrors the behaviour of a client
%% echoing its own frames back through the deflate/inflate pair.
roundtrip_test_() ->
    [{Size,
      fun() ->
          Data = crypto:strong_rand_bytes(Size),
          N = #{server_context_takeover => takeover,
                client_context_takeover => takeover,
                server_max_window_bits  => 15,
                client_max_window_bits  => 15},
          D = ws_deflate:init_deflate(N, server),
          I = ws_deflate:init_inflate(N, client),
          Wire = ws_deflate:deflate(D, takeover, Data),
          {ok, Back} = ws_deflate:inflate(I, takeover, Wire),
          ?assertEqual(Data, Back),
          zlib:close(D), zlib:close(I)
      end}
     || Size <- [0, 1, 16, 1024, 64000]].

%% ---------------------------------------------------------------------
%% Offer parsing + one-call negotiation.

parse_offer_plain_test() ->
    ?assertEqual({ok, []}, ws_deflate:parse_offer(<<"permessage-deflate">>)).

parse_offer_params_test() ->
    ?assertEqual(
        {ok, [<<"client_max_window_bits">>,
              {<<"server_max_window_bits">>, <<"10">>}]},
        ws_deflate:parse_offer(
            <<"permessage-deflate; client_max_window_bits; "
              "server_max_window_bits=10">>)).

parse_offer_quoted_value_test() ->
    ?assertEqual(
        {ok, [{<<"server_max_window_bits">>, <<"12">>}]},
        ws_deflate:parse_offer(
            <<"permessage-deflate; server_max_window_bits=\"12\"">>)).

parse_offer_other_extension_test() ->
    ?assertEqual(not_deflate, ws_deflate:parse_offer(<<"bbf-usp-protocol">>)).

negotiate_picks_first_acceptable_test() ->
    Exts = [<<"some-other-ext">>,
            <<"permessage-deflate; client_max_window_bits">>],
    {ok, Resp, Negotiated} = ws_deflate:negotiate(Exts, #{}),
    ?assertMatch(#{server_context_takeover := takeover}, Negotiated),
    ?assertMatch({_, _}, binary:match(iolist_to_binary(Resp),
                                      <<"permessage-deflate">>)).

negotiate_nothing_offered_test() ->
    ?assertEqual(ignore, ws_deflate:negotiate([<<"other">>], #{})),
    ?assertEqual(ignore, ws_deflate:negotiate([], #{})).
