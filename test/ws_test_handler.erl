%% @doc Echo handler shared by CT suites.
%%
%% Modes (picked via HandlerOpts):
%%   #{mode := echo}             — echoes text/binary/pong. Closes on close.
%%   #{mode := echo, notify := Pid} — as above, also forwards messages to Pid.
-module(ws_test_handler).
-behaviour(ws_handler).

-export([init/2, handle_in/2, handle_info/2, terminate/2]).

init(Req, Opts) ->
    notify(Opts, {init, Req}),
    {ok, Opts}.

handle_in({text, Data} = M, State) ->
    notify(State, M),
    {reply, {text, Data}, State};
handle_in({binary, Data} = M, State) ->
    notify(State, M),
    {reply, {binary, Data}, State};
handle_in({ping, _} = M, State) ->
    notify(State, M),
    {ok, State};
handle_in({pong, _} = M, State) ->
    notify(State, M),
    {ok, State};
handle_in(M, State) ->
    notify(State, M),
    {ok, State}.

handle_info({send, Frame}, State) ->
    {reply, Frame, State};
handle_info(Msg, State) ->
    notify(State, {info, Msg}),
    {ok, State}.

terminate(Reason, State) ->
    notify(State, {terminate, Reason}),
    ok.

notify(#{notify := Pid}, Msg) when is_pid(Pid) -> Pid ! {ws_test, Msg}, ok;
notify(_, _) -> ok.
