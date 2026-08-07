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

%% @doc RFC 7692 — permessage-deflate extension helpers.
%%
%% Provides negotiation (parse client offer / build server response),
%% and the inflate / deflate primitives used on the hot path once the
%% extension is enabled. The session does not yet wire this in
%% automatically — embedders enabling permessage-deflate should drive
%% it from their upgrade helper and pass the resulting zlib streams
%% into `encode_payload/3' / `decode_payload/3'.
%%
%% The algorithm follows the one in hackney_ws_proto / cowlib: deflate
%% with `sync' flush, strip the trailing `0x00 0x00 0xff 0xff' block on
%% the wire, and re-append it before calling inflate.
-module(ws_deflate).

-export([negotiate_server/2]).
-export([negotiate/2]).
-export([parse_offer/1]).
-export([client_offer/1]).
-export([parse_server_response/1]).
-export([init_inflate/2, init_deflate/2]).
-export([inflate/3, inflate/4, deflate/3]).

%% Default guard against deflate bombs: 64 MiB of inflated output
%% per call. Callers handling untrusted compressed input SHOULD pass
%% a tighter bound via `inflate/4'.
-define(DEFAULT_MAX_INFLATE, 64 * 1024 * 1024).

-type opts() :: #{
    server_context_takeover => takeover | no_takeover,
    client_context_takeover => takeover | no_takeover,
    server_max_window_bits  => 8..15,
    client_max_window_bits  => 8..15,
    level     => zlib:zlevel(),
    mem_level => zlib:zmemlevel(),
    strategy  => zlib:zstrategy()
}.

-type params() :: [{binary(), binary()} | binary()].

-type negotiated() :: #{
    server_context_takeover := takeover | no_takeover,
    client_context_takeover := takeover | no_takeover,
    server_max_window_bits  := 8..15,
    client_max_window_bits  := 8..15
}.

-export_type([opts/0, params/0, negotiated/0]).

%% ---------------------------------------------------------------------
%% Server-side negotiation. Takes the parsed offer params from the
%% client's `Sec-WebSocket-Extensions' and server policy in Opts.
%% Returns either `ignore' (cannot agree) or
%% `{ok, ResponseHeader :: iolist(), negotiated()}`.

%% @doc Negotiate against the peer's raw `Sec-WebSocket-Extensions'
%% offers as the upgrade validators deliver them (one binary per
%% comma-separated element, e.g. `<<"permessage-deflate;
%% client_max_window_bits">>'). Tries each permessage-deflate offer in
%% order and settles on the first that can be agreed on. Returns the
%% response header value (iolist) plus the negotiated parameters, or
%% `ignore' when the peer offered nothing acceptable.
-spec negotiate([binary()], opts()) -> ignore | {ok, iolist(), negotiated()}.
negotiate(Extensions, Opts) ->
    Offers = [Params || Ext <- Extensions, {ok, Params} <- [parse_offer(Ext)]],
    try_offers(Offers, Opts).

try_offers([], _Opts) -> ignore;
try_offers([Params | Rest], Opts) ->
    case negotiate_server(Params, Opts) of
        ignore -> try_offers(Rest, Opts);
        {ok, _, _} = Ok -> Ok
    end.

%% @doc Parse one `Sec-WebSocket-Extensions' element into `params()'
%% when it is a permessage-deflate offer.
-spec parse_offer(binary()) -> {ok, params()} | not_deflate.
parse_offer(Ext) when is_binary(Ext) ->
    [Name | Params] =
        [string:trim(P) || P <- binary:split(Ext, <<";">>, [global])],
    case Name of
        <<"permessage-deflate">> -> {ok, [parse_param(P) || P <- Params]};
        _ -> not_deflate
    end.

parse_param(P) ->
    case binary:split(P, <<"=">>) of
        [K] -> K;
        [K, V] -> {K, unquote(string:trim(V))}
    end.

unquote(<<$", Rest/binary>>) when byte_size(Rest) >= 1 ->
    case binary:last(Rest) of
        $" -> binary:part(Rest, 0, byte_size(Rest) - 1);
        _ -> Rest
    end;
unquote(V) ->
    V.

-spec negotiate_server(params(), opts()) ->
    ignore | {ok, iolist(), negotiated()}.
negotiate_server(Params, Opts) ->
    Dedup = lists:usort(Params),
    case length(Dedup) =:= length(Params) of
        false -> ignore;
        true -> negotiate1(Dedup, Opts)
    end.

negotiate1(Params, Opts) ->
    ServerCTO = maps:get(server_context_takeover, Opts, takeover),
    ClientCTO = maps:get(client_context_takeover, Opts, takeover),
    ServerWB  = maps:get(server_max_window_bits, Opts, 15),
    ClientWB  = maps:get(client_max_window_bits, Opts, 15),
    Negotiated0 = #{
        server_context_takeover => ServerCTO,
        client_context_takeover => ClientCTO,
        server_max_window_bits  => ServerWB,
        client_max_window_bits  => ClientWB
    },
    Resp0 = case ServerCTO of takeover -> []; no_takeover ->
                [<<"; server_no_context_takeover">>] end,
    Resp1 = case ClientCTO of takeover -> Resp0; no_takeover ->
                [<<"; client_no_context_takeover">> | Resp0] end,
    case walk_params(Params, Negotiated0, Resp1, ServerWB, ClientWB) of
        ignore -> ignore;
        {Negotiated, Resp} ->
            Resp2 = case maps:is_key(server_max_window_bits_set, Negotiated) of
                true -> Resp;
                false when ServerWB =:= 15 -> Resp;
                false -> [<<"; server_max_window_bits=">>,
                          integer_to_binary(ServerWB) | Resp]
            end,
            {ok, [<<"permessage-deflate">> | Resp2],
             maps:without([client_max_window_bits_set,
                           server_max_window_bits_set], Negotiated)}
    end.

walk_params([], Neg, Resp, _SWB, _CWB) ->
    {Neg, Resp};
walk_params([<<"client_max_window_bits">> | T], Neg, Resp, SWB, CWB) ->
    walk_params(T, Neg#{client_max_window_bits_set => true},
                [<<"; client_max_window_bits=">>,
                 integer_to_binary(maps:get(client_max_window_bits, Neg))
                 | Resp], SWB, CWB);
walk_params([{<<"client_max_window_bits">>, V} | T], Neg, Resp, SWB, CWB) ->
    case parse_window_bits(V) of
        error -> ignore;
        Bits when Bits =< CWB ->
            walk_params(T, Neg#{client_max_window_bits => Bits,
                                client_max_window_bits_set => true},
                        [<<"; client_max_window_bits=">>, V | Resp], SWB, CWB);
        _ ->
            walk_params(T, Neg#{client_max_window_bits_set => true},
                        [<<"; client_max_window_bits=">>,
                         integer_to_binary(CWB) | Resp], SWB, CWB)
    end;
walk_params([{<<"server_max_window_bits">>, V} | T], Neg, Resp, SWB, CWB) ->
    case parse_window_bits(V) of
        error -> ignore;
        Bits when Bits =< SWB ->
            walk_params(T, Neg#{server_max_window_bits => Bits,
                                server_max_window_bits_set => true},
                        [<<"; server_max_window_bits=">>, V | Resp], SWB, CWB);
        _ -> ignore
    end;
walk_params([<<"client_no_context_takeover">> | T], Neg, Resp, SWB, CWB) ->
    walk_params(T, Neg#{client_context_takeover => no_takeover}, Resp, SWB, CWB);
walk_params([<<"server_no_context_takeover">> | T], Neg, Resp, SWB, CWB) ->
    walk_params(T, Neg#{server_context_takeover => no_takeover}, Resp, SWB, CWB);
walk_params(_, _, _, _, _) ->
    ignore.

parse_window_bits(Bin) ->
    try binary_to_integer(Bin) of
        N when N >= 8, N =< 15 -> N;
        _ -> error
    catch _:_ -> error
    end.

%% ---------------------------------------------------------------------
%% Client side.

-spec client_offer(opts()) -> iodata().
client_offer(Opts) ->
    Base = [<<"permessage-deflate">>],
    C1 = case maps:get(client_context_takeover, Opts, takeover) of
        takeover    -> Base;
        no_takeover -> Base ++ [<<"; client_no_context_takeover">>]
    end,
    C2 = case maps:get(server_context_takeover, Opts, takeover) of
        takeover    -> C1;
        no_takeover -> C1 ++ [<<"; server_no_context_takeover">>]
    end,
    C3 = case maps:find(client_max_window_bits, Opts) of
        error       -> C2 ++ [<<"; client_max_window_bits">>];
        {ok, Bits}  -> C2 ++ [<<"; client_max_window_bits=">>,
                              integer_to_binary(Bits)]
    end,
    case maps:find(server_max_window_bits, Opts) of
        error       -> C3;
        {ok, SBits} -> C3 ++ [<<"; server_max_window_bits=">>,
                              integer_to_binary(SBits)]
    end.

-spec parse_server_response(params()) ->
    {ok, negotiated()} | {error, term()}.
parse_server_response(Params) ->
    walk_response(Params, #{
        server_context_takeover => takeover,
        client_context_takeover => takeover,
        server_max_window_bits  => 15,
        client_max_window_bits  => 15
    }).

walk_response([], N) -> {ok, N};
walk_response([{<<"client_max_window_bits">>, V} | T], N) ->
    case parse_window_bits(V) of
        error -> {error, bad_client_max_window_bits};
        B -> walk_response(T, N#{client_max_window_bits => B})
    end;
walk_response([<<"client_no_context_takeover">> | T], N) ->
    walk_response(T, N#{client_context_takeover => no_takeover});
walk_response([{<<"server_max_window_bits">>, V} | T], N) ->
    case parse_window_bits(V) of
        error -> {error, bad_server_max_window_bits};
        B -> walk_response(T, N#{server_max_window_bits => B})
    end;
walk_response([<<"server_no_context_takeover">> | T], N) ->
    walk_response(T, N#{server_context_takeover => no_takeover});
walk_response(_, _) ->
    {error, unknown_param}.

%% ---------------------------------------------------------------------
%% zlib stream setup.

-spec init_inflate(negotiated(), client | server) -> zlib:zstream().
init_inflate(#{client_max_window_bits := CBits, server_max_window_bits := SBits}, Role) ->
    Bits = case Role of client -> SBits; server -> CBits end,
    Z = zlib:open(),
    ok = zlib:inflateInit(Z, -Bits),
    Z.

-spec init_deflate(negotiated(), client | server) -> zlib:zstream().
init_deflate(#{client_max_window_bits := CBits, server_max_window_bits := SBits}, Role) ->
    Bits = case Role of client -> CBits; server -> SBits end,
    Z = zlib:open(),
    ok = zlib:deflateInit(Z, default, deflated, -Bits, 8, default),
    Z.

%% ---------------------------------------------------------------------
%% Codec.

-spec inflate(zlib:zstream(), takeover | no_takeover, iodata()) ->
    {ok, binary()} | {error, {inflate_too_big, pos_integer()}}.
inflate(Z, Takeover, Data) ->
    inflate(Z, Takeover, Data, ?DEFAULT_MAX_INFLATE).

-spec inflate(zlib:zstream(), takeover | no_takeover, iodata(),
              pos_integer() | infinity) ->
    {ok, binary()} | {error, {inflate_too_big, pos_integer() | infinity}}.
inflate(Z, Takeover, Data, MaxSize) ->
    %% Re-append the trailing empty block stripped on the wire, then
    %% feed the whole thing through `safeInflate' chunk-by-chunk so
    %% we can abort as soon as we cross `MaxSize' — a zlib bomb stops
    %% at the bound rather than allocating unbounded memory first.
    Input = iolist_to_binary([Data, <<0, 0, 255, 255>>]),
    case feed(Z, Input, MaxSize, 0, []) of
        {ok, Out} ->
            case Takeover of
                no_takeover -> ok = zlib:inflateReset(Z);
                takeover -> ok
            end,
            {ok, Out};
        {error, _} = E ->
            E
    end.

feed(Z, Input, MaxSize, Size, Acc) ->
    case zlib:safeInflate(Z, Input) of
        {finished, Chunk} ->
            NewSize = Size + iolist_size(Chunk),
            check_size(MaxSize, NewSize,
                       fun() -> {ok, iolist_to_binary(lists:reverse([Chunk | Acc]))} end);
        {continue, Chunk} ->
            NewSize = Size + iolist_size(Chunk),
            check_size(MaxSize, NewSize,
                       %% After the first call, `safeInflate' pulls
                       %% more output by being fed `[]' — the input
                       %% is already in the stream's buffer.
                       fun() -> feed(Z, [], MaxSize, NewSize, [Chunk | Acc]) end);
        {need_dictionary, _, _} ->
            {error, need_dictionary}
    end.

check_size(infinity, _, Cont) -> Cont();
check_size(Max, Size, _) when Size > Max ->
    {error, {inflate_too_big, Max}};
check_size(_, _, Cont) -> Cont().

-spec deflate(zlib:zstream(), takeover | no_takeover, iodata()) -> binary().
deflate(Z, Takeover, Data) ->
    Deflated = iolist_to_binary(zlib:deflate(Z, Data, sync)),
    case Takeover of
        no_takeover -> ok = zlib:deflateReset(Z);
        takeover -> ok
    end,
    Len = byte_size(Deflated) - 4,
    case Deflated of
        <<Body:Len/binary, 0:8, 0:8, 255:8, 255:8>> -> Body;
        <<>> -> <<0>>;
        _ -> Deflated
    end.
