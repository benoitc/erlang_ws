%% @doc Generic forwarding handler used by ws_examples_SUITE. Sends
%% every inbound frame as `{ws_forward, Frame}' to a notify pid.
-module(ws_examples_SUITE_forwarder).
-behaviour(ws_handler).

-export([init/2, handle_in/2, handle_info/2, terminate/2]).

init(_Req, #{notify := Pid} = State) when is_pid(Pid) ->
    {ok, State}.

handle_in(Frame, #{notify := Pid} = State) ->
    Pid ! {ws_forward, Frame},
    {ok, State}.

handle_info(_Msg, State) -> {ok, State}.
terminate(_Reason, _State) -> ok.
