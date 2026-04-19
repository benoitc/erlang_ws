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

%% @doc RFC 6455 handshake helpers for WebSocket over HTTP/1.1.
%%
%% Embedders provide a parsed HTTP request or response (method, target,
%% headers) and this module validates the WebSocket-specific pieces and
%% builds the peer-side headers. The embedder is responsible for
%% actually driving the socket: writing the request line / status line,
%% serialising the response headers, handing the byte stream over to
%% `ws_session' once the handshake is done.
%%
%% Headers are accepted in either `list({binary(), binary()})' or
%% `map()' shape; names are compared case-insensitively.
-module(ws_h1_upgrade).

-include("../include/ws.hrl").

-export([validate_request/1, validate_request/2]).
-export([response_headers/1, response_headers/2]).
-export([accept_key/1]).
-export([client_key/0]).
-export([build_request/3, build_request/4]).
-export([validate_response/2]).

-type header() :: {binary(), binary()}.
-type headers() :: [header()] | map().

-export_type([headers/0]).

-type request_opts() :: #{
    required_subprotocols => [binary()]
}.

-type request_info() :: #{
    key            := binary(),
    version        := binary(),
    subprotocols   := [binary()],
    extensions     := [binary()],
    accept         := binary(),
    origin         => binary()
}.

-type client_opts() :: #{
    subprotocols   => [binary()],
    extensions     => [binary()],
    extra_headers  => [header()],
    origin         => binary()
}.

-export_type([request_info/0, request_opts/0, client_opts/0]).

%% ---------------------------------------------------------------------
%% Server-side: validate the upgrade request.

-spec validate_request(headers()) -> {ok, request_info()} | {error, term()}.
validate_request(Headers) ->
    validate_request(Headers, #{}).

-spec validate_request(headers(), request_opts()) ->
    {ok, request_info()} | {error, term()}.
validate_request(Headers, Opts) ->
    H = normalize_headers(Headers),
    with_ok([
        fun() -> check_upgrade(H) end,
        fun() -> check_connection(H) end,
        fun() -> check_version(H) end,
        fun() -> check_key(H) end
     ],
     fun() ->
        Key = header_value(<<"sec-websocket-key">>, H),
        Accept = accept_key(Key),
        Subs = split_list(header_value(<<"sec-websocket-protocol">>, H)),
        Exts = split_list(header_value(<<"sec-websocket-extensions">>, H)),
        Info0 = #{
            key          => Key,
            version      => <<"13">>,
            subprotocols => Subs,
            extensions   => Exts,
            accept       => Accept
        },
        Info = case header_value(<<"origin">>, H) of
            undefined -> Info0;
            O -> Info0#{origin => O}
        end,
        check_subprotocols(Info, Opts)
     end).

with_ok([], Cont) -> Cont();
with_ok([F | Fs], Cont) ->
    case F() of
        ok -> with_ok(Fs, Cont);
        {error, _} = E -> E
    end.

check_upgrade(H) ->
    case header_value(<<"upgrade">>, H) of
        undefined -> {error, missing_upgrade_header};
        V ->
            case lists:member(<<"websocket">>,
                              lowercase_tokens(V)) of
                true -> ok;
                false -> {error, {invalid_upgrade, V}}
            end
    end.

check_connection(H) ->
    case header_value(<<"connection">>, H) of
        undefined -> {error, missing_connection_header};
        V ->
            case lists:member(<<"upgrade">>,
                              lowercase_tokens(V)) of
                true -> ok;
                false -> {error, {invalid_connection, V}}
            end
    end.

check_version(H) ->
    case header_value(<<"sec-websocket-version">>, H) of
        <<"13">> -> ok;
        V -> {error, {unsupported_version, V}}
    end.

check_key(H) ->
    case header_value(<<"sec-websocket-key">>, H) of
        undefined -> {error, missing_sec_websocket_key};
        Key when is_binary(Key) ->
            %% base64:decode/1 crashes on invalid input (byte length
            %% not multiple of 4, non-base64 chars, ...). Guard so a
            %% malformed header becomes a typed error rather than a
            %% crash the caller has to reason about.
            try base64:decode(Key) of
                Decoded when byte_size(Decoded) =:= 16 -> ok;
                _ -> {error, bad_sec_websocket_key}
            catch
                _:_ -> {error, bad_sec_websocket_key}
            end
    end.

check_subprotocols(Info, #{required_subprotocols := Required}) ->
    Offered = maps:get(subprotocols, Info, []),
    case [S || S <- Required, lists:member(S, Offered)] of
        [] -> {error, no_acceptable_subprotocol};
        [Sel | _] -> {ok, Info#{selected_subprotocol => Sel}}
    end;
check_subprotocols(Info, _) ->
    {ok, Info}.

%% ---------------------------------------------------------------------
%% Server-side: produce response headers.

-spec response_headers(request_info()) -> [header()].
response_headers(Info) ->
    response_headers(Info, #{}).

-spec response_headers(request_info(), map()) -> [header()].
response_headers(#{accept := Accept} = Info, ExtraOpts) ->
    Base = [{<<"upgrade">>, <<"websocket">>},
            {<<"connection">>, <<"Upgrade">>},
            {<<"sec-websocket-accept">>, Accept}],
    SubHdr = case maps:get(selected_subprotocol, Info, undefined) of
        undefined -> [];
        Sel -> [{<<"sec-websocket-protocol">>, Sel}]
    end,
    ExtHdr = case maps:get(extensions, ExtraOpts, undefined) of
        undefined -> [];
        Exts -> [{<<"sec-websocket-extensions">>,
                  iolist_to_binary(lists:join(<<", ">>, Exts))}]
    end,
    Base ++ SubHdr ++ ExtHdr.

-spec accept_key(binary()) -> binary().
accept_key(Key) when is_binary(Key) ->
    base64:encode(crypto:hash(sha, [Key, ?WS_GUID])).

%% ---------------------------------------------------------------------
%% Client-side: construct the upgrade request headers, then validate the
%% 101 response.

-spec client_key() -> binary().
client_key() ->
    base64:encode(crypto:strong_rand_bytes(16)).

-spec build_request(binary(), binary(), binary()) ->
    {Key :: binary(), Headers :: [header()]}.
build_request(Host, Port, Path) ->
    build_request(Host, Port, Path, #{}).

-spec build_request(binary(), binary() | integer(), binary(), client_opts()) ->
    {Key :: binary(), Headers :: [header()]}.
build_request(Host, Port, _Path, Opts) ->
    Key = client_key(),
    HostHdr = format_host(Host, Port),
    Base = [{<<"host">>, HostHdr},
            {<<"upgrade">>, <<"websocket">>},
            {<<"connection">>, <<"Upgrade">>},
            {<<"sec-websocket-key">>, Key},
            {<<"sec-websocket-version">>, <<"13">>}],
    Subs = maps:get(subprotocols, Opts, []),
    Exts = maps:get(extensions, Opts, []),
    Origin = maps:get(origin, Opts, undefined),
    Extra = maps:get(extra_headers, Opts, []),
    Hdrs = Base
        ++ optional_list(<<"sec-websocket-protocol">>, Subs)
        ++ optional_list(<<"sec-websocket-extensions">>, Exts)
        ++ optional_value(<<"origin">>, Origin)
        ++ Extra,
    {Key, Hdrs}.

format_host(Host, Port) when is_integer(Port) ->
    <<Host/binary, ":", (integer_to_binary(Port))/binary>>;
format_host(Host, Port) when is_binary(Port), Port =/= <<>> ->
    <<Host/binary, ":", Port/binary>>;
format_host(Host, _) ->
    Host.

-spec validate_response(integer(), headers()) ->
    {ok, #{accept := binary(), subprotocol => binary(), extensions => [binary()]}}
    | {error, term()}.
validate_response(Status, _Headers) when Status =/= 101 ->
    {error, {unexpected_status, Status}};
validate_response(101, Headers) ->
    H = normalize_headers(Headers),
    with_ok([
        fun() -> check_upgrade(H) end,
        fun() -> check_connection(H) end,
        fun() ->
            case header_value(<<"sec-websocket-accept">>, H) of
                undefined -> {error, missing_sec_websocket_accept};
                _ -> ok
            end
        end
     ],
     fun() ->
        Accept = header_value(<<"sec-websocket-accept">>, H),
        Info0 = #{accept => Accept},
        Info1 = case header_value(<<"sec-websocket-protocol">>, H) of
            undefined -> Info0;
            Proto -> Info0#{subprotocol => Proto}
        end,
        Info = case header_value(<<"sec-websocket-extensions">>, H) of
            undefined -> Info1;
            Exts -> Info1#{extensions => split_list(Exts)}
        end,
        {ok, Info}
     end).

%% ---------------------------------------------------------------------
%% helpers

normalize_headers(Map) when is_map(Map) ->
    normalize_headers(maps:to_list(Map));
normalize_headers(List) when is_list(List) ->
    [{lowercase(to_bin(K)), to_bin(V)} || {K, V} <- List].

header_value(Name, List) ->
    case lists:keyfind(Name, 1, List) of
        {_, V} -> V;
        false -> undefined
    end.

lowercase(Bin) when is_binary(Bin) -> string:lowercase(Bin).

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L)   -> list_to_binary(L);
to_bin(A) when is_atom(A)   -> atom_to_binary(A, utf8).

lowercase_tokens(Bin) when is_binary(Bin) ->
    [string:trim(string:lowercase(T)) || T <- binary:split(Bin, <<",">>, [global])].

split_list(undefined) -> [];
split_list(Bin) ->
    [string:trim(T) || T <- binary:split(Bin, <<",">>, [global]), T =/= <<>>].

optional_list(_, []) -> [];
optional_list(Name, Vs) ->
    [{Name, iolist_to_binary(lists:join(<<", ">>, Vs))}].

optional_value(_, undefined) -> [];
optional_value(Name, V) -> [{Name, V}].
