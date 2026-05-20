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

%% @doc Public entry point for the ws application.
%%
%%   ws:accept/5 — start a server-side session after the embedder has
%%                 validated the H1 / H2 / H3 upgrade.
%%   ws:connect/2 — convenience client connect for H1 (plain TCP / TLS).
%%   ws:send/2, ws:close/2, ws:close/3, ws:stop/1 — per-session control.
-module(ws).

-export([accept/5, accept/6]).
-export([connect/2]).
-export([send/2, close/2, close/3, stop/1]).

-type transport_mod() :: module().
-type handle() :: term().

-type accept_opts() :: #{
    parser_opts   => map(),
    idle_timeout  => timeout(),
    close_timeout => timeout()
}.

-export_type([transport_mod/0, handle/0, accept_opts/0]).

%% @doc Start a WebSocket session for an already-upgraded server stream.
%%
%%  TransportMod — module implementing `ws_transport'.
%%  Handle       — transport-specific handle (for `ws_transport_gen_tcp'
%%                 this is a `gen_tcp:socket()').
%%  Req          — request metadata map the handler will receive; keys
%%                 `method', `path', `headers', `subprotocols',
%%                 `extensions', `peer', ... are by convention.
%%  HandlerMod   — module implementing `ws_handler'.
%%  HandlerOpts  — opaque, passed straight to `HandlerMod:init/2'.
-spec accept(transport_mod(), handle(), Req :: map(), module(), term()) ->
    {ok, pid()} | {error, term()}.
accept(TransportMod, Handle, Req, HandlerMod, HandlerOpts) ->
    accept(TransportMod, Handle, Req, HandlerMod, HandlerOpts, #{}).

-spec accept(transport_mod(), handle(), map(), module(), term(), accept_opts()) ->
    {ok, pid()} | {error, term()}.
accept(TransportMod, Handle, Req, HandlerMod, HandlerOpts, Opts) ->
    StartOpts = maps:merge(Opts, #{
        transport    => TransportMod,
        handle       => Handle,
        role         => server,
        handler      => HandlerMod,
        handler_opts => HandlerOpts,
        req          => Req
    }),
    %% Use `start/1' (no link) so the session survives its initiator —
    %% embedders typically spawn a short-lived upgrade handler that
    %% exits after calling `ws:accept/5'.
    case ws_session:start(StartOpts) of
        {ok, Pid} ->
            case TransportMod:controlling_process(Handle, Pid) of
                ok ->
                    ok = ws_session:activate(Pid),
                    {ok, Pid};
                {error, _} = E ->
                    ws_session:stop(Pid),
                    E
            end;
        Err -> Err
    end.

%% @doc Client connect for `ws://' / `wss://' URLs over HTTP/1.1.
-spec connect(binary() | string(), map()) -> {ok, pid()} | {error, term()}.
connect(Url, Opts) ->
    ws_client:connect(Url, Opts).

send(Pid, Frames) -> ws_session:send(Pid, Frames).
close(Pid, Code) -> ws_session:close(Pid, Code).
close(Pid, Code, Reason) -> ws_session:close(Pid, Code, Reason).
stop(Pid) -> ws_session:stop(Pid).
