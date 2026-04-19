-module(ws_frame_tests).
-include_lib("eunit/include/eunit.hrl").
-include("../include/ws.hrl").

%% ---------------------------------------------------------------------
%% Encode.

encode_text_server_short_test() ->
    Iolist = ws_frame:encode({text, <<"hello">>}, server),
    ?assertEqual(<<16#81, 5, "hello">>, iolist_to_binary(Iolist)).

encode_text_server_126_test() ->
    Payload = binary:copy(<<"a">>, 126),
    Bin = iolist_to_binary(ws_frame:encode({text, Payload}, server)),
    <<16#81, 126, 126:16, Rest/binary>> = Bin,
    ?assertEqual(Payload, Rest).

encode_text_server_65536_test() ->
    Payload = binary:copy(<<"x">>, 65536),
    Bin = iolist_to_binary(ws_frame:encode({text, Payload}, server)),
    <<16#81, 127, Len:64, Rest/binary>> = Bin,
    ?assertEqual(65536, Len),
    ?assertEqual(Payload, Rest).

encode_ping_server_test() ->
    Bin = iolist_to_binary(ws_frame:encode({ping, <<"hi">>}, server)),
    ?assertEqual(<<16#89, 2, "hi">>, Bin).

encode_pong_server_test() ->
    Bin = iolist_to_binary(ws_frame:encode({pong, <<>>}, server)),
    ?assertEqual(<<16#8A, 0>>, Bin).

encode_close_server_bare_test() ->
    Bin = iolist_to_binary(ws_frame:encode(close, server)),
    ?assertEqual(<<16#88, 0>>, Bin).

encode_close_server_with_code_test() ->
    Bin = iolist_to_binary(ws_frame:encode({close, 1000, <<"bye">>}, server)),
    ?assertEqual(<<16#88, 5, 1000:16, "bye">>, Bin).

encode_client_frames_are_masked_test() ->
    Bin = iolist_to_binary(ws_frame:encode({text, <<"hi">>}, client)),
    <<16#81, 16#82, _MaskKey:32, Masked:2/binary>> = Bin,
    ?assert(Masked =/= <<"hi">>).

encode_control_too_big_crashes_test() ->
    %% Control frames must be <= 125 bytes.
    ?assertError(_, ws_frame:encode({ping, binary:copy(<<"x">>, 126)}, server)).

%% ---------------------------------------------------------------------
%% Mask / unmask symmetry.

mask_is_involution_test() ->
    Data = <<"The quick brown fox jumps over the lazy dog.">>,
    Key = 16#deadbeef,
    ?assertEqual(Data, ws_frame:mask(ws_frame:mask(Data, Key), Key)).

mask_arbitrary_sizes_test_() ->
    Key = 16#cafef00d,
    [?_assertEqual(B, ws_frame:mask(ws_frame:mask(B, Key), Key))
     || N <- [0, 1, 2, 3, 4, 5, 7, 8, 9, 15, 16, 17, 63, 64, 127, 128, 4095],
        B <- [binary:copy(<<"x">>, N)]].

%% ---------------------------------------------------------------------
%% Decode (server parser — inbound must be masked).

server_parser() ->
    ws_frame:init_parser(#{role => server}).

client_parser() ->
    ws_frame:init_parser(#{role => client}).

%% Build a frame the client would send (masked).
client_send(Frame) ->
    iolist_to_binary(ws_frame:encode(Frame, client)).

decode_text_test() ->
    {ok, Msgs, _} = ws_frame:parse(server_parser(), client_send({text, <<"hi">>})),
    ?assertEqual([{text, <<"hi">>}], Msgs).

decode_binary_test() ->
    Payload = <<1, 2, 3, 4, 5>>,
    {ok, Msgs, _} = ws_frame:parse(server_parser(), client_send({binary, Payload})),
    ?assertEqual([{binary, Payload}], Msgs).

decode_ping_pong_close_test() ->
    P0 = server_parser(),
    B  = <<(client_send({ping, <<"p">>}))/binary,
           (client_send({pong, <<>>}))/binary,
           (client_send({close, 1000, <<"bye">>}))/binary>>,
    {ok, Msgs, _} = ws_frame:parse(P0, B),
    ?assertEqual([{ping, <<"p">>}, {pong, <<>>}, {close, 1000, <<"bye">>}], Msgs).

decode_bare_close_test() ->
    {ok, Msgs, _} = ws_frame:parse(server_parser(), client_send(close)),
    ?assertEqual([close], Msgs).

decode_streamed_bytes_test() ->
    %% Feed a 129-byte binary frame one byte at a time.
    Payload = binary:copy(<<"y">>, 129),
    Full = client_send({binary, Payload}),
    {ok, Msgs, _} =
        lists:foldl(
          fun(<<B>>, {ok, Acc, P}) ->
                  {ok, M, P2} = ws_frame:parse(P, <<B>>),
                  {ok, Acc ++ M, P2}
          end, {ok, [], server_parser()}, [<<X>> || <<X>> <= Full]),
    ?assertEqual([{binary, Payload}], Msgs).

decode_unmasked_on_server_is_protocol_error_test() ->
    %% Craft an unmasked text frame; server parser must reject.
    Bad = <<16#81, 2, "hi">>,
    ?assertMatch({error, protocol_error, _},
                 ws_frame:parse(server_parser(), Bad)).

decode_masked_on_client_is_protocol_error_test() ->
    %% Client parser rejects masked server->client frames.
    Masked = client_send({text, <<"hi">>}),
    ?assertMatch({error, protocol_error, _},
                 ws_frame:parse(client_parser(), Masked)).

decode_rsv_nonzero_is_protocol_error_test() ->
    %% FIN=1 RSV1=1 opcode=text len=0
    Bad = <<16#C1, 16#80, 0:32>>,
    ?assertMatch({error, protocol_error, _},
                 ws_frame:parse(server_parser(), Bad)).

decode_control_with_fin0_is_protocol_error_test() ->
    %% FIN=0 opcode=ping len=0 mask=1
    Bad = <<16#09, 16#80, 0:32>>,
    ?assertMatch({error, protocol_error, _},
                 ws_frame:parse(server_parser(), Bad)).

decode_control_too_large_is_protocol_error_test() ->
    %% masked ping with 126-byte payload (control frames must be <=125).
    MaskKey = 0,
    Bad = <<16#89, 16#FE, 126:16, 0:32, 0:(126*8)>>,
    ?assertMatch({error, protocol_error, _},
                 ws_frame:parse(server_parser(), Bad)),
    _ = MaskKey, ok.

decode_bad_opcode_is_protocol_error_test() ->
    %% masked, FIN=1, opcode=3 (reserved non-control), len=0
    Bad = <<16#83, 16#80, 0:32>>,
    ?assertMatch({error, protocol_error, _},
                 ws_frame:parse(server_parser(), Bad)).

decode_close_length_1_is_protocol_error_test() ->
    Bad = <<16#88, 16#81, 0:32, 0:8>>,
    ?assertMatch({error, protocol_error, _},
                 ws_frame:parse(server_parser(), Bad)).

decode_close_invalid_code_is_error_test() ->
    %% code 1004 is reserved, cannot be sent.
    Bad = client_send({close, 1000, <<>>}),
    {ok, _, _} = ws_frame:parse(server_parser(), Bad),
    %% Now craft an illegal code manually.
    Payload = <<1004:16>>,
    MaskKey = 16#AABBCCDD,
    Masked = ws_frame:mask(Payload, MaskKey),
    Bad2 = <<16#88, 16#82, MaskKey:32, Masked/binary>>,
    ?assertMatch({error, bad_close_code, _},
                 ws_frame:parse(server_parser(), Bad2)).

decode_close_bad_utf8_reason_test() ->
    %% 1000 code with invalid UTF-8 reason bytes.
    BadUtf8 = <<1000:16, 16#F4, 16#90, 16#80, 16#80>>,
    MaskKey = 16#11223344,
    Masked = ws_frame:mask(BadUtf8, MaskKey),
    Bad = <<16#88, 16#86, MaskKey:32, Masked/binary>>,
    ?assertMatch({error, _, _}, ws_frame:parse(server_parser(), Bad)).

decode_text_with_bad_utf8_test() ->
    Payload = <<16#F4, 16#90, 16#80, 16#80>>, %% >U+10FFFF
    MaskKey = 16#12345678,
    Masked = ws_frame:mask(Payload, MaskKey),
    Bad = <<16#81, 16#84, MaskKey:32, Masked/binary>>,
    ?assertMatch({error, invalid_utf8, _},
                 ws_frame:parse(server_parser(), Bad)).

%% ---------------------------------------------------------------------
%% Fragmentation.

decode_fragmented_text_test() ->
    %% opcode=text FIN=0 "he"  +  opcode=cont FIN=1 "llo"
    %% Both masked because we are a server parser.
    MaskKey1 = 16#01020304,
    Part1 = ws_frame:mask(<<"he">>, MaskKey1),
    F1 = <<0:1, 0:3, 1:4, 1:1, 2:7, MaskKey1:32, Part1/binary>>,
    MaskKey2 = 16#05060708,
    Part2 = ws_frame:mask(<<"llo">>, MaskKey2),
    F2 = <<1:1, 0:3, 0:4, 1:1, 3:7, MaskKey2:32, Part2/binary>>,
    {ok, [], P1}    = ws_frame:parse(server_parser(), F1),
    {ok, Msgs, _}   = ws_frame:parse(P1, F2),
    ?assertEqual([{text, <<"hello">>}], Msgs).

decode_fragmented_utf8_split_codepoint_test() ->
    %% Split a 2-byte UTF-8 codepoint (U+00A9 ©) across two fragments.
    %% First fragment: opcode=text FIN=0, byte 1 of "©".
    Byte1 = 16#C2,
    Byte2 = 16#A9,
    MaskKey1 = 0,
    F1 = <<0:1, 0:3, 1:4, 1:1, 1:7, MaskKey1:32,
           (ws_frame:mask(<<Byte1>>, MaskKey1))/binary>>,
    MaskKey2 = 0,
    F2 = <<1:1, 0:3, 0:4, 1:1, 1:7, MaskKey2:32,
           (ws_frame:mask(<<Byte2>>, MaskKey2))/binary>>,
    {ok, [], P1}  = ws_frame:parse(server_parser(), F1),
    {ok, Msgs, _} = ws_frame:parse(P1, F2),
    ?assertEqual([{text, <<Byte1, Byte2>>}], Msgs).

decode_continuation_without_open_fragment_is_error_test() ->
    %% FIN=1 opcode=cont is illegal if no fragmented message is in progress.
    Bad = <<1:1, 0:3, 0:4, 1:1, 0:7, 0:32>>,
    ?assertMatch({error, protocol_error, _},
                 ws_frame:parse(server_parser(), Bad)).

decode_data_frame_during_fragment_is_error_test() ->
    %% Open fragment with text, then send another text frame instead of cont.
    MaskKey = 0,
    F1 = <<0:1, 0:3, 1:4, 1:1, 1:7, MaskKey:32,
           (ws_frame:mask(<<"a">>, MaskKey))/binary>>,
    F2 = <<1:1, 0:3, 1:4, 1:1, 1:7, MaskKey:32,
           (ws_frame:mask(<<"b">>, MaskKey))/binary>>,
    {ok, [], P1} = ws_frame:parse(server_parser(), F1),
    ?assertMatch({error, protocol_error, _},
                 ws_frame:parse(P1, F2)).

%% ---------------------------------------------------------------------
%% Size limits.

decode_message_too_big_single_frame_test() ->
    %% 16-bit length frame exceeding default max frame. Default is 16 MiB;
    %% use a parser with a small limit instead.
    Small = ws_frame:init_parser(#{role => server, max_frame => 4}),
    MaskKey = 0,
    Payload = binary:copy(<<"y">>, 10),
    Masked = ws_frame:mask(Payload, MaskKey),
    Bad = <<1:1, 0:3, 2:4, 1:1, 10:7, MaskKey:32, Masked/binary>>,
    ?assertMatch({error, message_too_big, _}, ws_frame:parse(Small, Bad)).

decode_message_too_big_fragmented_test() ->
    Small = ws_frame:init_parser(#{role => server, max_message => 4}),
    MaskKey = 0,
    F1 = <<0:1, 0:3, 2:4, 1:1, 3:7, MaskKey:32,
           (ws_frame:mask(<<1, 2, 3>>, MaskKey))/binary>>,
    F2 = <<1:1, 0:3, 0:4, 1:1, 3:7, MaskKey:32,
           (ws_frame:mask(<<4, 5, 6>>, MaskKey))/binary>>,
    {ok, [], P1} = ws_frame:parse(Small, F1),
    ?assertMatch({error, message_too_big, _}, ws_frame:parse(P1, F2)).

%% ---------------------------------------------------------------------
%% Round-trip sanity on varied shapes, using a client encoder -> server parser.

roundtrip_text_empty_test() ->
    Frame = {text, <<>>},
    {ok, [Got], _} = ws_frame:parse(server_parser(), client_send(Frame)),
    ?assertEqual(Frame, Got).

roundtrip_text_unicode_test() ->
    Frame = {text, <<"héllo 世界 🦀"/utf8>>},
    {ok, [Got], _} = ws_frame:parse(server_parser(), client_send(Frame)),
    ?assertEqual(Frame, Got).

roundtrip_large_binary_test() ->
    Frame = {binary, crypto:strong_rand_bytes(200000)},
    {ok, [Got], _} = ws_frame:parse(server_parser(), client_send(Frame)),
    ?assertEqual(Frame, Got).

roundtrip_server_to_client_test() ->
    %% Server encoder + client parser.
    Frame = {text, <<"ping from server">>},
    Bin = iolist_to_binary(ws_frame:encode(Frame, server)),
    {ok, [Got], _} = ws_frame:parse(client_parser(), Bin),
    ?assertEqual(Frame, Got).
