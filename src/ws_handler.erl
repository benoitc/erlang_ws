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
