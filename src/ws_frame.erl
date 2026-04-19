%% Copyright 2026 Benoit Chesneau
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.

%% @doc RFC 6455 frame codec.
%%
%% Responsibilities:
%%  - Encode outbound frames (masked for clients, unmasked for servers).
%%  - Decode a stream of inbound bytes into a list of complete messages,
%%    transparently reassembling continuation fragments.
%%  - Enforce protocol invariants listed in RFC 6455: RSV bits zero when
%%    no extension is negotiated, control frames ≤ 125 bytes and not
%%    fragmented, minimal length encoding, mask bit matching the sender
%%    role, UTF-8 validity for text payloads and close reasons, valid
%%    close codes (§7.4).
%%
%% The parser returns whole message frames only; partial fragments are
%% accumulated internally. If a fragmented message exceeds `max_message'
%% or a single frame exceeds `max_frame', the parser errors with
%% `message_too_big' (close code 1009).
%%
%% The UTF-8 DFA and masking loop are adapted from
%% hackney_ws_proto (itself derived from cowlib/cow_ws).
-module(ws_frame).

-include("../include/ws.hrl").

-export([init_parser/0, init_parser/1]).
-export([parse/2]).
-export([encode/2]).
-export([mask/2]).

-export_type([parser/0, frame/0, message/0, role/0, error_reason/0]).

-type role() :: client | server.
-type parser() :: #ws_parser{}.

-type message() ::
      {text, binary()}
    | {binary, binary()}
    | {ping, binary()}
    | {pong, binary()}
    | {close, ws_close:code(), binary()}
    | close.

-type frame() ::
      {text, iodata()}
    | {binary, iodata()}
    | {ping, iodata()}
    | {pong, iodata()}
    | {close, ws_close:code(), iodata()}
    | close.

-type error_reason() ::
      protocol_error
    | invalid_utf8
    | message_too_big
    | bad_close_code.

%% ---------------------------------------------------------------------
%% Parser construction

-spec init_parser() -> parser().
init_parser() ->
    init_parser(#{}).

-spec init_parser(map()) -> parser().
init_parser(Opts) when is_map(Opts) ->
    #ws_parser{
        role       = maps:get(role, Opts, server),
        max_frame   = maps:get(max_frame,   Opts, ?WS_DEFAULT_MAX_FRAME_SIZE),
        max_message = maps:get(max_message, Opts, ?WS_DEFAULT_MAX_MESSAGE_SIZE)
    }.

%% ---------------------------------------------------------------------
%% Public parse/2

-spec parse(parser(), binary()) ->
    {ok, [message()], parser()} | {error, error_reason(), parser()}.
parse(P = #ws_parser{buffer = Buf}, Data) when is_binary(Data) ->
    parse_loop(P#ws_parser{buffer = <<Buf/binary, Data/binary>>}, []).

parse_loop(P, Acc) ->
    case parse_one(P) of
        more ->
            {ok, lists:reverse(Acc), P};
        {ok, Msg, P2} ->
            parse_loop(P2, [Msg | Acc]);
        {fragment, P2} ->
            parse_loop(P2, Acc);
        {error, Reason} ->
            {error, Reason, P}
    end.

%% ---------------------------------------------------------------------
%% Single frame decode. Returns `more', `{ok, Msg, P}' when a full
%% message has been produced (a single frame, or the final fragment
%% completing an accumulator), `{fragment, P}' when the frame consumed
%% was an intermediate piece of a fragmented message, or `{error, R}'.

parse_one(P = #ws_parser{buffer = Buf, role = Role,
                         max_frame = MaxFrame,
                         max_message = MaxMessage,
                         frag_op = FragOp,
                         frag_size = FragSize,
                         utf8_state = Utf8In}) ->
    case decode_header(Buf, Role, FragOp) of
        more ->
            more;
        {error, _} = E ->
            E;
        {ok, _Fin, Opcode, Len, _Mask, _Rest} when Len > MaxFrame,
                                                    Opcode < 8 ->
            {error, message_too_big};
        {ok, _Fin, Opcode, Len, _Mask, _Rest} when Opcode >= 8, Len > 125 ->
            {error, protocol_error};
        {ok, Fin, Opcode, Len, Mask, Rest} ->
            case byte_size(Rest) of
                N when N < Len ->
                    more;
                _ ->
                    <<Payload0:Len/binary, After/binary>> = Rest,
                    Payload = unmask(Payload0, Mask),
                    handle_frame(P, Fin, Opcode, Payload, After,
                                 FragSize, MaxMessage, Utf8In)
            end
    end.

%% --- handle_frame -----------------------------------------------------

handle_frame(P, Fin, ?WS_OP_PING, Payload, After, _FragSize, _MaxMsg, _U) ->
    case Fin of
        1 -> {ok, {ping, Payload}, P#ws_parser{buffer = After}};
        0 -> {error, protocol_error}
    end;
handle_frame(P, Fin, ?WS_OP_PONG, Payload, After, _FragSize, _MaxMsg, _U) ->
    case Fin of
        1 -> {ok, {pong, Payload}, P#ws_parser{buffer = After}};
        0 -> {error, protocol_error}
    end;
handle_frame(P, Fin, ?WS_OP_CLOSE, Payload, After, _FragSize, _MaxMsg, _U)
        when Fin =:= 1 ->
    case parse_close_payload(Payload) of
        close ->
            {ok, close, P#ws_parser{buffer = After}};
        {ok, Code, Reason} ->
            {ok, {close, Code, Reason}, P#ws_parser{buffer = After}};
        {error, _} = E ->
            E
    end;
handle_frame(_P, 0, ?WS_OP_CLOSE, _Payload, _After, _FragSize, _MaxMsg, _U) ->
    {error, protocol_error};

%% Text frame. Either final (fin=1) producing a full message, or the
%% opening of a fragmented message.
handle_frame(P = #ws_parser{}, 1, ?WS_OP_TEXT, Payload, After, _FS, _MaxMsg, _U) ->
    case validate_utf8(Payload, 0) of
        0 ->
            {ok, {text, Payload}, P#ws_parser{buffer = After}};
        _ ->
            {error, invalid_utf8}
    end;
handle_frame(P = #ws_parser{}, 0, ?WS_OP_TEXT, Payload, After, _FS, MaxMsg, _U) ->
    case byte_size(Payload) of
        N when N > MaxMsg ->
            {error, message_too_big};
        N ->
            case validate_utf8_stream(Payload, 0) of
                {error, _} = E -> E;
                {ok, Utf8State} ->
                    {fragment, P#ws_parser{
                        buffer = After,
                        frag_op = text,
                        frag_acc = [Payload],
                        frag_size = N,
                        utf8_state = Utf8State}}
            end
    end;

handle_frame(P = #ws_parser{}, 1, ?WS_OP_BINARY, Payload, After, _FS, _MaxMsg, _U) ->
    {ok, {binary, Payload}, P#ws_parser{buffer = After}};
handle_frame(P = #ws_parser{}, 0, ?WS_OP_BINARY, Payload, After, _FS, MaxMsg, _U) ->
    case byte_size(Payload) of
        N when N > MaxMsg ->
            {error, message_too_big};
        N ->
            {fragment, P#ws_parser{
                buffer = After,
                frag_op = binary,
                frag_acc = [Payload],
                frag_size = N,
                utf8_state = 0}}
    end;

%% Continuation frames.
handle_frame(P = #ws_parser{frag_op = FragOp, frag_acc = Acc, frag_size = FS,
                            utf8_state = Utf8State}, 1, ?WS_OP_CONT,
             Payload, After, _FS, MaxMsg, _U) when FragOp =/= undefined ->
    NewSize = FS + byte_size(Payload),
    case NewSize of
        N when N > MaxMsg ->
            {error, message_too_big};
        _ ->
            Full = iolist_to_binary(lists:reverse([Payload | Acc])),
            case FragOp of
                text ->
                    case validate_utf8(Payload, Utf8State) of
                        0 ->
                            P2 = reset_fragment(P#ws_parser{buffer = After}),
                            {ok, {text, Full}, P2};
                        _ ->
                            {error, invalid_utf8}
                    end;
                binary ->
                    P2 = reset_fragment(P#ws_parser{buffer = After}),
                    {ok, {binary, Full}, P2}
            end
    end;
handle_frame(P = #ws_parser{frag_op = FragOp, frag_acc = Acc, frag_size = FS,
                            utf8_state = Utf8State}, 0, ?WS_OP_CONT,
             Payload, After, _FS, MaxMsg, _U) when FragOp =/= undefined ->
    NewSize = FS + byte_size(Payload),
    case NewSize of
        N when N > MaxMsg ->
            {error, message_too_big};
        _ ->
            case FragOp of
                text ->
                    case validate_utf8_stream(Payload, Utf8State) of
                        {error, _} = E -> E;
                        {ok, Utf8State2} ->
                            {fragment, P#ws_parser{
                                buffer = After,
                                frag_acc = [Payload | Acc],
                                frag_size = NewSize,
                                utf8_state = Utf8State2}}
                    end;
                binary ->
                    {fragment, P#ws_parser{
                        buffer = After,
                        frag_acc = [Payload | Acc],
                        frag_size = NewSize}}
            end
    end;
handle_frame(_P, _Fin, ?WS_OP_CONT, _Payload, _After, _FS, _MaxMsg, _U) ->
    %% Continuation without an open fragmented message.
    {error, protocol_error}.

reset_fragment(P) ->
    P#ws_parser{frag_op = undefined, frag_acc = [], frag_size = 0, utf8_state = 0}.

%% ---------------------------------------------------------------------
%% Header decode. Returns `more`, `{error, protocol_error}`, or
%% `{ok, Fin, Opcode, Len, Mask|undefined, Rest}`.

decode_header(Buf, _Role, _FragOp) when byte_size(Buf) < 2 ->
    more;
decode_header(<<_Fin:1, Rsv:3, _:4, _/bits>>, _Role, _FragOp) when Rsv =/= 0 ->
    {error, protocol_error};
decode_header(<<_:4, Opcode:4, _/bits>>, _Role, _FragOp) when Opcode > 2,
                                                              Opcode < 8 ->
    {error, protocol_error};
decode_header(<<_:4, Opcode:4, _/bits>>, _Role, _FragOp) when Opcode > 10 ->
    {error, protocol_error};
decode_header(<<0:1, _:3, Opcode:4, _/bits>>, _Role, _FragOp) when Opcode >= 8 ->
    %% Control frames must have fin=1.
    {error, protocol_error};
decode_header(<<_:4, ?WS_OP_CONT:4, _/bits>>, _Role, undefined) ->
    %% Continuation with no open fragmented message.
    {error, protocol_error};
decode_header(<<_:4, Opcode:4, _/bits>>, _Role, FragOp) when FragOp =/= undefined,
                                                             Opcode =/= ?WS_OP_CONT,
                                                             Opcode < 8 ->
    %% Expected continuation but got a new data frame.
    {error, protocol_error};
%% Close frame with length == 1 is illegal (must be 0 or >= 2).
decode_header(<<_:4, ?WS_OP_CLOSE:4, _:1, 1:7, _/bits>>, _Role, _FragOp) ->
    {error, protocol_error};
%% Mask bit must match sender role:
%%  - When we are the server, inbound frames MUST be masked.
%%  - When we are the client, inbound frames MUST NOT be masked.
decode_header(<<_:8, 0:1, _/bits>>, server, _FragOp) ->
    {error, protocol_error};
decode_header(<<_:8, 1:1, _/bits>>, client, _FragOp) ->
    {error, protocol_error};
%% 7-bit length, no mask.
decode_header(<<Fin:1, 0:3, Op:4, 0:1, Len:7, Rest/bits>>, _Role, _FragOp) when Len < 126 ->
    {ok, Fin, Op, Len, undefined, Rest};
decode_header(<<Fin:1, 0:3, Op:4, 1:1, Len:7, Mask:32, Rest/bits>>, _Role, _FragOp) when Len < 126 ->
    {ok, Fin, Op, Len, Mask, Rest};
%% 16-bit length. Must be > 125. Control frames cannot use it.
decode_header(<<Fin:1, 0:3, Op:4, 0:1, 126:7, Len:16, Rest/bits>>, _Role, _FragOp)
  when Len > 125, Op < 8 ->
    {ok, Fin, Op, Len, undefined, Rest};
decode_header(<<Fin:1, 0:3, Op:4, 1:1, 126:7, Len:16, Mask:32, Rest/bits>>, _Role, _FragOp)
  when Len > 125, Op < 8 ->
    {ok, Fin, Op, Len, Mask, Rest};
%% 63-bit length. Top bit must be zero.
decode_header(<<Fin:1, 0:3, Op:4, 0:1, 127:7, 0:1, Len:63, Rest/bits>>, _Role, _FragOp)
  when Len > 16#ffff, Op < 8 ->
    {ok, Fin, Op, Len, undefined, Rest};
decode_header(<<Fin:1, 0:3, Op:4, 1:1, 127:7, 0:1, Len:63, Mask:32, Rest/bits>>, _Role, _FragOp)
  when Len > 16#ffff, Op < 8 ->
    {ok, Fin, Op, Len, Mask, Rest};
%% MSB of 63-bit length set.
decode_header(<<_:9, 127:7, 1:1, _/bits>>, _Role, _FragOp) ->
    {error, protocol_error};
%% Non-minimal length encoding.
decode_header(<<_:8, 0:1, 126:7, _:16, _/bits>>, _Role, _FragOp) ->
    {error, protocol_error};
decode_header(<<_:8, 1:1, 126:7, _:48, _/bits>>, _Role, _FragOp) ->
    {error, protocol_error};
decode_header(<<_:8, 0:1, 127:7, _:64, _/bits>>, _Role, _FragOp) ->
    {error, protocol_error};
decode_header(<<_:8, 1:1, 127:7, _:96, _/bits>>, _Role, _FragOp) ->
    {error, protocol_error};
decode_header(_, _, _) ->
    more.

%% ---------------------------------------------------------------------
%% Close frame payload parsing + validation.

parse_close_payload(<<>>) ->
    close;
parse_close_payload(<<Code:16, Reason/binary>>) ->
    case ws_close:valid_on_wire(Code) of
        false -> {error, bad_close_code};
        true ->
            case validate_utf8(Reason, 0) of
                0 -> {ok, Code, Reason};
                _ -> {error, invalid_utf8}
            end
    end.

%% ---------------------------------------------------------------------
%% Masking (XOR). Symmetric: mask/unmask share the same routine.

unmask(Data, undefined) -> Data;
unmask(Data, MaskKey) when is_integer(MaskKey) -> mask_bytes(Data, MaskKey).

%% @doc Mask or unmask `Data' with the 32-bit `MaskKey'.
-spec mask(binary(), 0..16#ffffffff) -> binary().
mask(Data, MaskKey) -> mask_bytes(Data, MaskKey).

mask_bytes(Data, MaskKey) -> mask_bytes(Data, MaskKey, <<>>).

mask_bytes(<<O1:32, O2:32, O3:32, O4:32, Rest/bits>>, K, Acc) ->
    T1 = O1 bxor K, T2 = O2 bxor K, T3 = O3 bxor K, T4 = O4 bxor K,
    mask_bytes(Rest, K, <<Acc/binary, T1:32, T2:32, T3:32, T4:32>>);
mask_bytes(<<O:32, Rest/bits>>, K, Acc) ->
    T = O bxor K,
    mask_bytes(Rest, K, <<Acc/binary, T:32>>);
mask_bytes(<<O:24>>, K, Acc) ->
    <<K2:24, _:8>> = <<K:32>>,
    T = O bxor K2,
    <<Acc/binary, T:24>>;
mask_bytes(<<O:16>>, K, Acc) ->
    <<K2:16, _:16>> = <<K:32>>,
    T = O bxor K2,
    <<Acc/binary, T:16>>;
mask_bytes(<<O:8>>, K, Acc) ->
    <<K2:8, _:24>> = <<K:32>>,
    T = O bxor K2,
    <<Acc/binary, T:8>>;
mask_bytes(<<>>, _, Acc) ->
    Acc.

%% ---------------------------------------------------------------------
%% Encode.

-spec encode(frame(), role()) -> iodata().
encode(close, server) ->
    <<1:1, 0:3, ?WS_OP_CLOSE:4, 0:8>>;
encode(close, client) ->
    <<1:1, 0:3, ?WS_OP_CLOSE:4, 1:1, 0:39>>;
encode({close, Code, Reason}, Role) ->
    Bin = iolist_to_binary([<<Code:16>>, Reason]),
    true = byte_size(Bin) =< 125,
    encode_masked_or_plain(Role, ?WS_OP_CLOSE, Bin);
encode({ping, Payload}, Role) ->
    Bin = iolist_to_binary(Payload),
    true = byte_size(Bin) =< 125,
    encode_masked_or_plain(Role, ?WS_OP_PING, Bin);
encode({pong, Payload}, Role) ->
    Bin = iolist_to_binary(Payload),
    true = byte_size(Bin) =< 125,
    encode_masked_or_plain(Role, ?WS_OP_PONG, Bin);
encode({text, Payload}, Role) ->
    encode_masked_or_plain(Role, ?WS_OP_TEXT, iolist_to_binary(Payload));
encode({binary, Payload}, Role) ->
    encode_masked_or_plain(Role, ?WS_OP_BINARY, iolist_to_binary(Payload)).

encode_masked_or_plain(server, Opcode, Bin) ->
    Len = payload_length_bits(byte_size(Bin)),
    [<<1:1, 0:3, Opcode:4, 0:1, Len/bits>>, Bin];
encode_masked_or_plain(client, Opcode, Bin) ->
    MaskKey = rand_mask_key(),
    MaskBin = <<MaskKey:32>>,
    Len = payload_length_bits(byte_size(Bin)),
    [<<1:1, 0:3, Opcode:4, 1:1, Len/bits>>, MaskBin, mask(Bin, MaskKey)].

rand_mask_key() ->
    <<Key:32>> = crypto:strong_rand_bytes(4),
    Key.

payload_length_bits(N) when N =< 125 -> <<N:7>>;
payload_length_bits(N) when N =< 16#ffff -> <<126:7, N:16>>;
payload_length_bits(N) when N =< 16#7fffffffffffffff -> <<127:7, N:64>>.

%% ---------------------------------------------------------------------
%% UTF-8 validation (Hoehrmann DFA).
%%
%% Returns 0 when all bytes parsed cleanly to a valid boundary, 1 on
%% invalid sequence, 2..8 when ending in the middle of a multi-byte
%% codepoint. Callers that stream bytes across frames pass the returned
%% state back in on the next call.
%%
%% validate_utf8/2 accepts only a terminal 0 as "valid", useful for
%% whole-payload validation. validate_utf8_stream/2 returns the state
%% wrapped so streaming callers can tell "partial but not broken" from
%% "invalid".

validate_utf8(Bin, State) ->
    v_text(Bin, State).

validate_utf8_stream(Bin, State) ->
    case v_text(Bin, State) of
        1 -> {error, invalid_utf8};
        N -> {ok, N}
    end.

v_text(Text, 0) -> v_ascii(Text);
v_text(Text, 2) -> v_s2(Text);
v_text(Text, 3) -> v_s3(Text);
v_text(Text, 4) -> v_s4(Text);
v_text(Text, 5) -> v_s5(Text);
v_text(Text, 6) -> v_s6(Text);
v_text(Text, 7) -> v_s7(Text);
v_text(Text, 8) -> v_s8(Text).

v_ascii(<<>>) -> 0;
v_ascii(<<C1, C2, C3, C4, R/bits>>) when C1 < 128, C2 < 128, C3 < 128, C4 < 128 ->
    v_ascii(R);
v_ascii(<<C1, R/bits>>) when C1 < 128 -> v_ascii(R);
v_ascii(Text) -> v_s0(Text).

v_s0(<<C, R/bits>>) when C >= 128 ->
    case element(C - 127, utf8_class()) of
        2  -> v_s2(R);
        3  -> v_s3(R);
        6  -> v_s7(R);
        4  -> v_s5(R);
        5  -> v_s8(R);
        10 -> v_s4(R);
        11 -> v_s6(R);
        _  -> 1
    end;
v_s0(Text) ->
    v_ascii(Text).

v_s2(<<C, R/bits>>) ->
    case element(C - 127, utf8_class()) of
        7 -> v_s0(R); 1 -> v_s0(R); 9 -> v_s0(R); _ -> 1
    end;
v_s2(<<>>) -> 2.

v_s3(<<C, R/bits>>) ->
    case element(C - 127, utf8_class()) of
        7 -> v_s2(R); 1 -> v_s2(R); 9 -> v_s2(R); _ -> 1
    end;
v_s3(<<>>) -> 3.

v_s4(<<C, R/bits>>) ->
    case element(C - 127, utf8_class()) of
        7 -> v_s2(R); _ -> 1
    end;
v_s4(<<>>) -> 4.

v_s5(<<C, R/bits>>) ->
    case element(C - 127, utf8_class()) of
        1 -> v_s2(R); 9 -> v_s2(R); _ -> 1
    end;
v_s5(<<>>) -> 5.

v_s6(<<C, R/bits>>) ->
    case element(C - 127, utf8_class()) of
        7 -> v_s3(R); 9 -> v_s3(R); _ -> 1
    end;
v_s6(<<>>) -> 6.

v_s7(<<C, R/bits>>) ->
    case element(C - 127, utf8_class()) of
        7 -> v_s3(R); 1 -> v_s3(R); 9 -> v_s3(R); _ -> 1
    end;
v_s7(<<>>) -> 7.

v_s8(<<C, R/bits>>) ->
    case element(C - 127, utf8_class()) of
        1 -> v_s3(R); _ -> 1
    end;
v_s8(<<>>) -> 8.

-compile({inline, [utf8_class/0]}).
utf8_class() ->
    {
     1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,
     9,9,9,9,9,9,9,9,9,9,9,9,9,9,9,9,
     7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,
     7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,
     8,8,2,2,2,2,2,2,2,2,2,2,2,2,2,2,
     2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,
     10,3,3,3,3,3,3,3,3,3,3,3,3,4,3,3,
     11,6,6,6,5,8,8,8,8,8,8,8,8,8,8,8
    }.
