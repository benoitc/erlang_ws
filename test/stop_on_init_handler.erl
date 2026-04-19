%% @doc Handler that immediately stops during init. Used by
%% ws_security_SUITE to verify the session tears itself down cleanly.
-module(stop_on_init_handler).
-behaviour(ws_handler).

-export([init/2, handle_in/2, handle_info/2, terminate/2]).

init(_Req, _Opts) ->
    {stop, rejected_by_handler}.

handle_in(_, State) -> {ok, State}.
handle_info(_, State) -> {ok, State}.
terminate(_, _) -> ok.
