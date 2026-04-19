%% @doc PropEr properties for ws_frame: encode/decode round-trip,
%% mask involution, chunked delivery preserves message order.
-module(ws_prop_tests).

-ifdef(PROPER).

-include_lib("proper/include/proper.hrl").

%% --- generators -------------------------------------------------------

payload() ->
    ?LET(N, integer(0, 4096), binary(N)).

utf8_payload() ->
    ?LET(List, list(integer(0, 16#10FFFF)),
         unicode:characters_to_binary(List, unicode, utf8)).

frame() ->
    frequency([
        {4, {text, utf8_payload()}},
        {4, {binary, payload()}},
        {1, {ping, ?LET(N, integer(0, 125), binary(N))}},
        {1, {pong, ?LET(N, integer(0, 125), binary(N))}}
    ]).

mask_key() -> integer(0, 16#ffffffff).

%% --- properties -------------------------------------------------------

prop_mask_is_involution() ->
    ?FORALL({B, K}, {payload(), mask_key()},
            B =:= ws_frame:mask(ws_frame:mask(B, K), K)).

prop_client_to_server_roundtrip() ->
    ?FORALL(F, frame(),
            begin
                P = ws_frame:init_parser(#{role => server}),
                Bin = iolist_to_binary(ws_frame:encode(F, client)),
                case ws_frame:parse(P, Bin) of
                    {ok, [Decoded], _} -> normalize(F) =:= normalize(Decoded);
                    _ -> false
                end
            end).

prop_server_to_client_roundtrip() ->
    ?FORALL(F, frame(),
            begin
                P = ws_frame:init_parser(#{role => client}),
                Bin = iolist_to_binary(ws_frame:encode(F, server)),
                case ws_frame:parse(P, Bin) of
                    {ok, [Decoded], _} -> normalize(F) =:= normalize(Decoded);
                    _ -> false
                end
            end).

prop_chunked_delivery_preserves_messages() ->
    ?FORALL({Fs, Split}, {non_empty(list(frame())), integer(1, 64)},
            begin
                P0 = ws_frame:init_parser(#{role => server}),
                Full = iolist_to_binary([ws_frame:encode(F, client) || F <- Fs]),
                {ok, One, _} = ws_frame:parse(P0, Full),
                Chunks = chunks(Full, Split),
                {ok, Acc, _} =
                    lists:foldl(
                      fun(C, {ok, A, P}) ->
                              {ok, M, P2} = ws_frame:parse(P, C),
                              {ok, A ++ M, P2}
                      end, {ok, [], P0}, Chunks),
                One =:= Acc
            end).

%% --- helpers ----------------------------------------------------------

normalize({text, P})     -> {text, iolist_to_binary(P)};
normalize({binary, P})   -> {binary, iolist_to_binary(P)};
normalize({ping, P})     -> {ping, iolist_to_binary(P)};
normalize({pong, P})     -> {pong, iolist_to_binary(P)};
normalize(close)         -> close;
normalize({close, C, P}) -> {close, C, iolist_to_binary(P)}.

chunks(<<>>, _N) -> [];
chunks(B, N) when byte_size(B) =< N -> [B];
chunks(B, N) ->
    <<H:N/binary, Rest/binary>> = B,
    [H | chunks(Rest, N)].

-endif.
