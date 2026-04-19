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

%% @doc `ws_transport' implementation over OTP `ssl'. Used by the
%% client for `wss://' URLs. Mirrors `ws_transport_gen_tcp' in every
%% respect except the module calls and message shape.
-module(ws_transport_ssl).
-behaviour(ws_transport).

-export([send/2, activate/1, close/1, controlling_process/2, peername/1]).
-export([classify/2, recv/2]).

send(Sock, Data) ->
    ssl:send(Sock, Data).

activate(Sock) ->
    ssl:setopts(Sock, [{active, once}]).

close(Sock) ->
    ssl:close(Sock).

controlling_process(Sock, Pid) ->
    ssl:controlling_process(Sock, Pid).

peername(Sock) ->
    ssl:peername(Sock).

classify({ssl, Sock, Data}, Sock) ->        {ws_data, Sock, Data};
classify({ssl_closed, Sock}, Sock) ->       {ws_closed, Sock};
classify({ssl_error, Sock, Reason}, Sock) -> {ws_error, Sock, Reason};
classify(_Other, _Sock) ->                   ignore.

recv(Sock, Timeout) ->
    ssl:recv(Sock, 0, Timeout).
