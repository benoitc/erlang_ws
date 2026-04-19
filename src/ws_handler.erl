%% @doc User handler behaviour. The session dispatches inbound messages
%% and out-of-band Erlang messages to the callback module supplied at
%% `ws:accept/5' / `ws:connect/2' time.
%%
%% All callbacks return one of:
%%   {ok,    State}               — continue, no outbound frames.
%%   {reply, Frames, State}       — continue, send `Frames' (list).
%%   {stop,  Reason, State}       — tear the session down.
%%
%% `Frames' is a single frame or a list of frames in the shape accepted
%% by `ws_frame:encode/2'. The session auto-responds to ping frames
%% with a matching pong *before* invoking `handle_in/2', so handlers
%% do not need to do so themselves unless they want custom behaviour.
-module(ws_handler).

-type frame() :: ws_frame:frame().
-type reply(State) :: {ok, State}
                    | {reply, frame() | [frame()], State}
                    | {stop, term(), State}.
-export_type([frame/0, reply/1]).

-callback init(Req :: map(), State) -> reply(State).
-callback handle_in(ws_frame:message(), State) -> reply(State).
-callback handle_info(term(), State) -> reply(State).
-callback terminate(term(), term()) -> ok.

-optional_callbacks([handle_info/2, terminate/2]).
