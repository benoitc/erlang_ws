%% @doc Handler used by ws_examples_SUITE subprotocol test: sends the
%% full upgrade-response info map (which contains `subprotocol') back
%% to a notify pid via `{subprotocol_info, Info}'.
-module(ws_examples_SUITE_subprotocol_probe).
-behaviour(ws_handler).

-export([init/2, handle_in/2, handle_info/2, terminate/2]).

init(Req, #{notify := Pid} = State) when is_pid(Pid) ->
    Info = maps:get(response, Req, #{}),
    Pid ! {subprotocol_info, Info},
    {ok, State}.

handle_in(_Frame, State) -> {ok, State}.
handle_info(_Msg, State) -> {ok, State}.
terminate(_Reason, _State) -> ok.
