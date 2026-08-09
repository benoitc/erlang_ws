%% @doc Server handler that greets from `init/2', before the peer has
%% said anything. The session writes that frame straight after the
%% embedder's 101, which is what lets the two land in the client's
%% first recv. Used by `ws_examples_SUITE' to drive the end-to-end
%% coalescing case with both sides running the real library.
-module(greeting_server_handler).
-behaviour(ws_handler).

-export([init/2, handle_in/2, handle_info/2, terminate/2]).

init(_Req, #{greeting := Greeting} = State) ->
    {reply, {text, Greeting}, State}.

handle_in({text, Data}, State) ->
    {reply, {text, Data}, State};
handle_in(_Frame, State) ->
    {ok, State}.

handle_info(_Msg, State) -> {ok, State}.
terminate(_Reason, _State) -> ok.
