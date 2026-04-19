%% === docs/guide.md "Running a client" ===
-module(snippet_client_relay).
-behaviour(ws_handler).
-export([init/2, handle_in/2, handle_info/2, terminate/2]).

init(_Req, #{notify := Pid} = State) when is_pid(Pid) ->
    {ok, State}.

handle_in(Frame, State = #{notify := Pid}) ->
    Pid ! {ws, Frame},
    {ok, State}.

handle_info(_, State) -> {ok, State}.
terminate(_, _) -> ok.
