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

%% @doc Reference `ws_transport' implementation over plain `gen_tcp'.
%%
%% Used by the CT test suite as the embedder stand-in. Translates
%% `tcp' / `tcp_closed' / `tcp_error' messages into the canonical
%% `ws_*' messages the session consumes.
-module(ws_transport_gen_tcp).
-behaviour(ws_transport).

-export([send/2, activate/1, close/1, controlling_process/2, peername/1]).
-export([classify/2, recv/2]).

send(Sock, Data) ->
    gen_tcp:send(Sock, Data).

activate(Sock) ->
    inet:setopts(Sock, [{active, once}]).

close(Sock) ->
    gen_tcp:close(Sock).

controlling_process(Sock, Pid) ->
    gen_tcp:controlling_process(Sock, Pid).

peername(Sock) ->
    inet:peername(Sock).

classify({tcp, Sock, Data}, Sock) ->        {ws_data, Sock, Data};
classify({tcp_closed, Sock}, Sock) ->       {ws_closed, Sock};
classify({tcp_error, Sock, Reason}, Sock) -> {ws_error, Sock, Reason};
classify(_Other, _Sock) ->                   ignore.

recv(Sock, Timeout) ->
    gen_tcp:recv(Sock, 0, Timeout).
