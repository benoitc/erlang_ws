%% @doc RFC 9220 — Bootstrapping WebSockets with HTTP/3.
%%
%% RFC 9220 reuses the RFC 8441 extended CONNECT pattern on top of
%% HTTP/3 streams. The only wire-level differences (capsule framing,
%% SETTINGS_ENABLE_CONNECT_PROTOCOL carried in H3 settings) live in
%% the embedder's H3 stack (erlang_quic's h3 module). From this
%% module's point of view the pseudo-header validation and response
%% shape are identical to HTTP/2 — so we reuse `ws_h2_upgrade' under
%% the hood and expose the name for discoverability.
-module(ws_h3_upgrade).

-export([validate_request/1, validate_request/2]).
-export([response_headers/1]).
-export([client_request/4, client_request/5]).
-export([validate_response/2]).

validate_request(Headers) -> ws_h2_upgrade:validate_request(Headers).
validate_request(Headers, Opts) -> ws_h2_upgrade:validate_request(Headers, Opts).

response_headers(Info) -> ws_h2_upgrade:response_headers(Info).

client_request(Scheme, Authority, Path, Opts) ->
    ws_h2_upgrade:client_request(Scheme, Authority, Path, Opts).
client_request(Scheme, Authority, Path, Opts, Extra) ->
    ws_h2_upgrade:client_request(Scheme, Authority, Path, Opts, Extra).

validate_response(Status, Hdrs) ->
    ws_h2_upgrade:validate_response(Status, Hdrs).
