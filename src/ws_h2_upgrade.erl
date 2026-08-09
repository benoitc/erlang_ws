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

%% @doc RFC 8441 — Bootstrapping WebSockets with HTTP/2.
%%
%% This module only deals with the pseudo-header / response-status
%% validation. Actually driving the HTTP/2 stream (sending the request,
%% receiving the response, swapping data frames for WebSocket frames)
%% belongs to the embedder; erlang_h2 already enforces the semantics
%% and the handshake details below mirror that.
%%
%% Caller responsibilities (server-side):
%%   * Before receiving any Extended CONNECT, the HTTP/2 stack must
%%     have advertised `SETTINGS_ENABLE_CONNECT_PROTOCOL = 1'. If the
%%     peer sent `:protocol' without having seen that setting it is
%%     the erlang_h2 layer that rejects the stream.
%%   * After this module returns `{ok, Info}', the embedder issues a
%%     200 response with the headers from `response_headers/1' and
%%     hands the stream bytes to `ws:accept/5'.
%%
%% Caller responsibilities (client-side):
%%   * `peer_enable_connect_protocol' must be true (the peer advertised
%%     `SETTINGS_ENABLE_CONNECT_PROTOCOL = 1'). `client_request/4'
%%     returns an error when that is not the case.
-module(ws_h2_upgrade).

-export([validate_request/1, validate_request/2]).
-export([response_headers/1]).
-export([client_request/4, client_request/5]).
-export([validate_response/2]).

-type pseudo_headers() :: [{binary(), binary()}] | map().
-type request_opts() :: #{
    required_subprotocols => [binary()]
}.
-type request_info() :: #{
    method     := binary(),
    protocol   := binary(),
    scheme     := binary(),
    authority  := binary(),
    path       := binary(),
    version    := binary(),
    subprotocols := [binary()],
    extensions := [binary()],
    selected_subprotocol => binary()
}.
-type client_opts() :: #{
    subprotocols  => [binary()],
    extensions    => [binary()],
    peer_enable_connect_protocol := boolean(),
    origin        => binary(),
    extra_headers => [{binary(), binary()}]
}.

-export_type([pseudo_headers/0, request_opts/0, request_info/0, client_opts/0]).

%% ---------------------------------------------------------------------
%% Server validation.

-spec validate_request(pseudo_headers()) ->
    {ok, request_info()} | {error, term()}.
validate_request(Headers) ->
    validate_request(Headers, #{}).

-spec validate_request(pseudo_headers(), request_opts()) ->
    {ok, request_info()} | {error, term()}.
validate_request(Headers, Opts) ->
    H = normalize(Headers),
    with_ok([
        fun() -> require(<<":method">>, <<"CONNECT">>, H, wrong_method) end,
        fun() -> require(<<":protocol">>, <<"websocket">>, H, wrong_protocol) end,
        fun() -> require_present(<<":scheme">>, H, missing_scheme) end,
        fun() -> require_present(<<":authority">>, H, missing_authority) end,
        fun() -> require_present(<<":path">>, H, missing_path) end,
        fun() -> check_version(H) end
     ],
     fun() ->
        Info0 = #{
            method    => value(<<":method">>, H),
            protocol  => value(<<":protocol">>, H),
            scheme    => value(<<":scheme">>, H),
            authority => value(<<":authority">>, H),
            path      => value(<<":path">>, H),
            version   => <<"13">>,
            subprotocols => split_list(value(<<"sec-websocket-protocol">>, H)),
            extensions   => split_list(value(<<"sec-websocket-extensions">>, H))
        },
        check_subprotocols(Info0, Opts)
     end).

%% RFC 8441 section 5 drops Sec-WebSocket-Key and Sec-WebSocket-Accept,
%% since `:protocol' supersedes them, but keeps Sec-WebSocket-Version
%% "as defined in [RFC6455]". Same check and same error shape as
%% `ws_h1_upgrade:check_version/1'.
check_version(H) ->
    case value(<<"sec-websocket-version">>, H) of
        <<"13">> -> ok;
        V -> {error, {unsupported_version, V}}
    end.

check_subprotocols(Info, #{required_subprotocols := Required}) ->
    Offered = maps:get(subprotocols, Info),
    case [S || S <- Required, lists:member(S, Offered)] of
        [] -> {error, no_acceptable_subprotocol};
        [Sel | _] -> {ok, Info#{selected_subprotocol => Sel}}
    end;
check_subprotocols(Info, _) ->
    {ok, Info}.

%% ---------------------------------------------------------------------
%% Server response.

-spec response_headers(request_info()) -> [{binary(), binary()}].
response_headers(Info) ->
    Base = [{<<":status">>, <<"200">>}],
    SubHdr = case maps:get(selected_subprotocol, Info, undefined) of
        undefined -> [];
        Sel -> [{<<"sec-websocket-protocol">>, Sel}]
    end,
    Base ++ SubHdr.

%% ---------------------------------------------------------------------
%% Client request construction + response validation.

-spec client_request(binary(), binary(), binary(), client_opts()) ->
    {ok, [{binary(), binary()}]} | {error, term()}.
client_request(Scheme, Authority, Path, Opts) ->
    client_request(Scheme, Authority, Path, Opts, []).

-spec client_request(binary(), binary(), binary(), client_opts(),
                     [{binary(), binary()}]) ->
    {ok, [{binary(), binary()}]} | {error, term()}.
client_request(_Scheme, _Authority, _Path,
               #{peer_enable_connect_protocol := false} = _Opts, _Extra) ->
    {error, peer_does_not_allow_connect_protocol};
client_request(Scheme, Authority, Path, Opts, Extra) ->
    Base = [{<<":method">>,    <<"CONNECT">>},
            {<<":protocol">>,  <<"websocket">>},
            {<<":scheme">>,    Scheme},
            {<<":authority">>, Authority},
            {<<":path">>,      Path}],
    Subs = maps:get(subprotocols, Opts, []),
    Exts = maps:get(extensions, Opts, []),
    Origin = maps:get(origin, Opts, undefined),
    Rest = [{<<"sec-websocket-version">>, <<"13">>}]
        ++ optional_list(<<"sec-websocket-protocol">>, Subs)
        ++ optional_list(<<"sec-websocket-extensions">>, Exts)
        ++ optional_value(<<"origin">>, Origin)
        ++ maps:get(extra_headers, Opts, [])
        ++ Extra,
    {ok, Base ++ Rest}.

-spec validate_response(integer(), [{binary(), binary()}]) ->
    {ok, #{subprotocol => binary(), extensions => [binary()]}}
    | {error, term()}.
validate_response(Status, _Hdrs) when Status div 100 =/= 2 ->
    {error, {unexpected_status, Status}};
validate_response(_Status, Hdrs) ->
    H = normalize(Hdrs),
    Info0 = #{},
    Info1 = case value(<<"sec-websocket-protocol">>, H) of
        undefined -> Info0;
        S -> Info0#{subprotocol => S}
    end,
    Info = case value(<<"sec-websocket-extensions">>, H) of
        undefined -> Info1;
        E -> Info1#{extensions => split_list(E)}
    end,
    {ok, Info}.

%% ---------------------------------------------------------------------
%% Helpers (shared in spirit with ws_h1_upgrade).

with_ok([], K) -> K();
with_ok([F | Fs], K) ->
    case F() of
        ok -> with_ok(Fs, K);
        {error, _} = E -> E
    end.

require(Name, Expected, H, Err) ->
    case value(Name, H) of
        Expected -> ok;
        _ -> {error, Err}
    end.

require_present(Name, H, Err) ->
    case value(Name, H) of
        undefined -> {error, Err};
        _ -> ok
    end.

normalize(Map) when is_map(Map) ->
    normalize(maps:to_list(Map));
normalize(List) when is_list(List) ->
    [{lowercase(to_bin(K)), to_bin(V)} || {K, V} <- List].

value(Name, H) ->
    case lists:keyfind(Name, 1, H) of
        {_, V} -> V;
        false -> undefined
    end.

lowercase(Bin) -> string:lowercase(Bin).

to_bin(B) when is_binary(B) -> B;
to_bin(A) when is_atom(A)   -> atom_to_binary(A, utf8);
to_bin(L) when is_list(L)   -> list_to_binary(L).

split_list(undefined) -> [];
split_list(Bin) ->
    [string:trim(T) || T <- binary:split(Bin, <<",">>, [global]), T =/= <<>>].

optional_list(_, []) -> [];
optional_list(Name, Vs) ->
    [{Name, iolist_to_binary(lists:join(<<", ">>, Vs))}].

optional_value(_, undefined) -> [];
optional_value(Name, V) -> [{Name, V}].
