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

%% @doc Example: chat broadcast server.
%%
%% Each connected WebSocket is registered against a shared `pg' group;
%% every text frame received from one client is rebroadcast to all
%% clients currently in the group.
%%
%% Shows how to:
%%   * Keep per-connection state.
%%   * Use `handle_info/2' to deliver out-of-band messages as frames.
%%   * Clean up on `terminate/2'.
-module(chat_server).

-behaviour(ws_handler).

-export([run/0, run/1]).
-export([init/2, handle_in/2, handle_info/2, terminate/2]).

-define(GROUP, chat_server_clients).

run() -> run(#{}).

run(Opts) ->
    Port = maps:get(port, Opts, 8081),
    {ok, _} = application:ensure_all_started(ws),
    _ = pg:start_link(),
    {ok, Pid} = ws_h1_tcp_server:start_link(
        #{port => Port, handler => ?MODULE, handler_opts => #{}}),
    io:format("chat_server listening on ws://127.0.0.1:~p/~n", [Port]),
    receive stop -> ws_h1_tcp_server:stop(Pid) end.

%% --- ws_handler callbacks --------------------------------------------

init(_Req, State) ->
    ok = pg:join(?GROUP, self()),
    {ok, State}.

handle_in({text, Data}, State) ->
    broadcast(Data),
    {ok, State};
handle_in(_, State) ->
    {ok, State}.

handle_info({broadcast, Data}, State) ->
    {reply, {text, Data}, State};
handle_info(_, State) ->
    {ok, State}.

terminate(_Reason, _State) ->
    _ = (try pg:leave(?GROUP, self()) catch _:_ -> ok end),
    ok.

%% --- helpers ---------------------------------------------------------

broadcast(Data) ->
    Me = self(),
    Members = pg:get_members(?GROUP),
    [P ! {broadcast, Data} || P <- Members, P =/= Me],
    ok.
