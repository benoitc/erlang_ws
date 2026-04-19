%% @doc Example: echo WebSocket server.
%%
%% Every text or binary frame the server receives is echoed back on
%% the same connection. Ping frames are automatically answered with a
%% pong by the session machinery.
%%
%% Run standalone:
%%
%%     rebar3 as test compile
%%     erl -pa _build/test/lib/ws/ebin _build/test/lib/ws/examples \
%%         -s echo_server run -noshell
%%
%% Connect with a browser or `websocat':
%%
%%     websocat ws://127.0.0.1:8080/
-module(echo_server).

-behaviour(ws_handler).

-export([run/0, run/1]).
-export([init/2, handle_in/2, handle_info/2, terminate/2]).

run() -> run(#{}).

run(Opts) ->
    Port = maps:get(port, Opts, 8080),
    {ok, _} = application:ensure_all_started(ws),
    {ok, Pid} = ws_h1_tcp_server:start_link(
        #{port => Port, handler => ?MODULE, handler_opts => #{}}),
    io:format("echo_server listening on ws://127.0.0.1:~p/~n", [Port]),
    receive stop -> ws_h1_tcp_server:stop(Pid) end.

%% --- ws_handler callbacks --------------------------------------------

init(_Req, State) ->
    {ok, State}.

handle_in({text, Data}, State) ->
    {reply, {text, Data}, State};
handle_in({binary, Data}, State) ->
    {reply, {binary, Data}, State};
handle_in(_, State) ->
    {ok, State}.

handle_info(_Msg, State) ->
    {ok, State}.

terminate(_Reason, _State) ->
    ok.
