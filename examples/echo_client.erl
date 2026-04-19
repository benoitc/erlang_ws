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

%% @doc Example: synchronous echo client.
%%
%% Sends a user-supplied text message, waits for the server's echo,
%% closes the connection cleanly.
%%
%%     echo_client:send(<<"ws://127.0.0.1:8080/">>, <<"hello">>).
-module(echo_client).

-behaviour(ws_handler).

-export([send/2, send/3]).
-export([init/2, handle_in/2, handle_info/2, terminate/2]).

-spec send(binary(), binary()) -> {ok, binary()} | {error, term()}.
send(Url, Msg) -> send(Url, Msg, 5000).

-spec send(binary(), binary(), timeout()) -> {ok, binary()} | {error, term()}.
send(Url, Msg, Timeout) ->
    {ok, _} = application:ensure_all_started(ws),
    case ws:connect(Url,
            #{handler      => ?MODULE,
              handler_opts => #{notify => self()}}) of
        {ok, Conn} ->
            ok = ws:send(Conn, {text, Msg}),
            Result = receive
                {echo, Bin} -> {ok, Bin}
            after Timeout ->
                {error, timeout}
            end,
            ok = ws:close(Conn, 1000, <<>>),
            Result;
        Err -> Err
    end.

%% --- ws_handler callbacks --------------------------------------------

init(_Req, #{notify := Pid} = State) when is_pid(Pid) ->
    {ok, State}.

handle_in({text, Data}, #{notify := Pid} = State) ->
    Pid ! {echo, Data},
    {ok, State};
handle_in(_, State) ->
    {ok, State}.

handle_info(_Msg, State) ->
    {ok, State}.

terminate(_Reason, _State) ->
    ok.
