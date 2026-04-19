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

%% @doc Transport behaviour — a thin abstraction the session uses to
%% exchange bytes on the stream handle supplied by the embedder.
%%
%% Inbound bytes reach the session as plain Erlang messages; the
%% transport module is responsible for turning adapter-specific
%% messages (`{tcp, ...}', `{ssl, ...}', `{h2_stream, ...}') into the
%% canonical shapes below:
%%
%%   {ws_data,   Handle, Bin}
%%   {ws_closed, Handle}
%%   {ws_error,  Handle, Reason}
%%
%% The session calls `activate/1' when it wants the next batch of
%% bytes. Transports that deliver continuously (e.g. `ssl' in
%% `active, true' mode) may simply return `ok'.
-module(ws_transport).

-callback send(Handle :: term(), iodata()) -> ok | {error, term()}.
-callback activate(Handle :: term()) -> ok | {error, term()}.
-callback close(Handle :: term()) -> ok.
-callback controlling_process(Handle :: term(), pid()) ->
    ok | {error, term()}.
%% Classify an arbitrary Erlang message against this transport's
%% handle. Returning `ignore' hands the message back to the session to
%% dispatch as an out-of-band info to the user handler.
-callback classify(Msg :: term(), Handle :: term()) ->
    {ws_data, term(), binary()}
    | {ws_closed, term()}
    | {ws_error, term(), term()}
    | ignore.
%% Synchronous read used by the client while driving the HTTP/1.1
%% handshake (when the session has not yet taken ownership of the
%% stream). Transports whose handshake happens elsewhere (e.g. an
%% HTTP/2 stream handle) may omit this and only be used server-side.
-callback recv(Handle :: term(), timeout()) ->
    {ok, binary()} | {error, term()}.
-callback peername(Handle :: term()) ->
    {ok, {inet:ip_address(), inet:port_number()}} | {error, term()}.

-optional_callbacks([recv/2, peername/1]).
