%% @doc Test handler used by `ws_client_SUITE'. Forwards every inbound
%% message to the notify pid in its options.
-module(client_forwarder_handler).
-behaviour(ws_handler).

-export([init/2, handle_in/2, handle_info/2, terminate/2]).

init(_Req, #{notify := Pid} = Opts) when is_pid(Pid) ->
    {ok, Opts}.

handle_in(Msg, State = #{notify := Pid}) ->
    Pid ! {ws_client_msg, Msg},
    {ok, State}.

handle_info(_Msg, State) ->
    {ok, State}.

terminate(_Reason, _State) ->
    ok.
