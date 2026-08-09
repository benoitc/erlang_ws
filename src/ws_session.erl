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

%% @doc WebSocket session state machine.
%%
%% Owns a single stream handle (supplied by the embedder through a
%% `ws_transport' callback), drives the frame codec, auto-responds to
%% control frames, and dispatches inbound messages to the user handler
%% module.
%%
%% States:
%%   open    — handshake complete, frames flowing in both directions.
%%   closing — a close frame was sent or received; the other direction
%%             may still finish.
%%   closed  — both directions closed; the process is about to exit.
%%
%% Inbound-byte delivery is pull-based: after consuming a chunk the
%% session calls `TransportMod:activate/1' to request the next one. The
%% transport signals fresh bytes with `{ws_data, Handle, Bin}', peer
%% close with `{ws_closed, Handle}', and socket-level errors with
%% `{ws_error, Handle, Reason}'.
-module(ws_session).
-behaviour(gen_statem).

-export([start_link/1, start/1]).
-export([activate/1]).
-export([send/2, close/2, close/3, stop/1]).

-export([init/1, callback_mode/0, terminate/3, code_change/4]).
-export([ready_wait/3, open/3, closing/3]).

-include("../include/ws.hrl").

-record(st, {
    transport_mod :: module(),
    handle :: term(),
    role :: client | server,
    parser :: ws_frame:parser(),
    handler_mod :: module(),
    handler_state :: term(),
    close_sent = false :: boolean(),
    close_received = false :: boolean(),
    %% Close info received from the peer, reported to the handler's
    %% terminate/2 as {remote, Code, Reason} (or `remote' for a bare
    %% close frame with no status code).
    peer_close = undefined :: undefined | remote | {ws_close:code(), binary()},
    %% permessage-deflate state once negotiated (RFC 7692): zlib
    %% streams plus per-direction context-takeover policy.
    deflate = undefined ::
        undefined
        | #{inflate := zlib:zstream(),
            deflate := zlib:zstream(),
            inflate_takeover := takeover | no_takeover,
            deflate_takeover := takeover | no_takeover,
            max_inflate := pos_integer() | infinity},
    idle_timeout = ?WS_DEFAULT_IDLE_TIMEOUT   :: timeout(),
    close_timeout = ?WS_DEFAULT_CLOSE_TIMEOUT :: timeout(),
    %% Bytes handed over by the embedder that arrived before the session
    %% owned the socket (a client's handshake recv can coalesce the first
    %% server frame with the 101). Replayed at activation, then cleared.
    pending = <<>> :: binary()
}).

-type start_opts() :: #{
    transport := module(),
    handle    := term(),
    role      := client | server,
    handler   := module(),
    handler_opts => term(),
    req       => map(),
    parser_opts => map(),
    %% Negotiated permessage-deflate parameters (from
    %% ws_deflate:negotiate/2 or ws_deflate:parse_server_response/1).
    %% Enables compression on both directions of the session.
    deflate => ws_deflate:negotiated(),
    idle_timeout => timeout(),
    close_timeout => timeout(),
    initial_data => binary()
}.

-export_type([start_opts/0]).

%% ---------------------------------------------------------------------
%% API

-spec start_link(start_opts()) -> {ok, pid()} | {error, term()}.
start_link(Opts) ->
    gen_statem:start_link(?MODULE, Opts, []).

-spec start(start_opts()) -> {ok, pid()} | {error, term()}.
start(Opts) ->
    gen_statem:start(?MODULE, Opts, []).

%% @doc Tell the session the embedder has finished transport setup
%% (ownership transfer and friends) — the session may now read bytes.
-spec activate(pid()) -> ok.
activate(Pid) ->
    gen_statem:cast(Pid, activate).

-spec send(pid(), ws_frame:frame() | [ws_frame:frame()]) -> ok.
send(Pid, FrameOrFrames) ->
    gen_statem:cast(Pid, {send, frames(FrameOrFrames)}).

-spec close(pid(), ws_close:code()) -> ok.
close(Pid, Code) -> close(Pid, Code, <<>>).

-spec close(pid(), ws_close:code(), iodata()) -> ok.
close(Pid, Code, Reason) ->
    gen_statem:cast(Pid, {close, Code, iolist_to_binary(Reason)}).

-spec stop(pid()) -> ok.
stop(Pid) -> gen_statem:stop(Pid).

%% ---------------------------------------------------------------------
%% gen_statem callbacks

callback_mode() -> state_functions.

init(#{transport := TM, handle := H, role := Role,
       handler := HMod} = Opts) ->
    ParserOpts = maps:get(parser_opts, Opts, #{}),
    Deflate = case maps:get(deflate, Opts, undefined) of
        undefined -> undefined;
        Negotiated -> init_deflate_state(Negotiated, Role, ParserOpts)
    end,
    ParserOpts1 = case Deflate of
        undefined -> ParserOpts;
        _ -> ParserOpts#{compress => true}
    end,
    Parser = ws_frame:init_parser(ParserOpts1#{role => Role}),
    HOpts = maps:get(handler_opts, Opts, #{}),
    Req = maps:get(req, Opts, #{}),
    St0 = #st{transport_mod = TM, handle = H, role = Role,
              parser = Parser, handler_mod = HMod,
              deflate = Deflate,
              idle_timeout = maps:get(idle_timeout, Opts,
                                      ?WS_DEFAULT_IDLE_TIMEOUT),
              close_timeout = maps:get(close_timeout, Opts,
                                       ?WS_DEFAULT_CLOSE_TIMEOUT),
              pending = maps:get(initial_data, Opts, <<>>)},
    case HMod:init(Req, HOpts) of
        {ok, HState} ->
            post_init(St0#st{handler_state = HState}, []);
        {reply, Frames, HState} ->
            post_init(St0#st{handler_state = HState}, frames(Frames));
        {stop, Reason} ->
            _ = TM:close(H),
            {stop, Reason}
    end.

post_init(St, Frames) ->
    case send_frames(Frames, St) of
        {ok, St2} ->
            %% Defer activation until the embedder calls
            %% `ws_session:activate/1' — otherwise an earlier
            %% `inet:setopts' can deliver bytes to the original socket
            %% owner before `controlling_process/2' has run.
            {ok, ready_wait, St2};
        {error, Reason} ->
            {stop, Reason}
    end.

%% --- ready_wait state -------------------------------------------------
%%
%% Frames can be queued via `send' while we wait; inbound bytes cannot
%% arrive yet because the transport has not been activated.

ready_wait(cast, activate, St = #st{transport_mod = TM, handle = H,
                                    pending = <<>>}) ->
    ok = TM:activate(H),
    {next_state, open, St, idle_action(St)};
ready_wait(cast, activate, St = #st{pending = Bin}) when Bin =/= <<>> ->
    %% Bytes arrived coalesced with the handshake. Enter `open' and replay
    %% them via an internal event, which is processed *before* any socket
    %% message — so the transport is not activated (and cannot deliver new
    %% bytes) until the drain has run, keeping the coalesced frame first.
    {next_state, open, St#st{pending = <<>>},
     [{next_event, internal, {drain, Bin}}]};
ready_wait(cast, {send, Frames}, St) ->
    case send_frames(Frames, St) of
        {ok, St2} -> {keep_state, St2};
        {error, Reason} -> {stop, Reason, St}
    end;
ready_wait(cast, {close, Code, Reason}, St) ->
    initiate_close(Code, Reason, St);
ready_wait(_EventType, _Msg, _St) ->
    keep_state_and_data.

%% --- open state -------------------------------------------------------

%% Replay the bytes that were coalesced with the handshake, exactly as the
%% `info' clause parses socket bytes. `dispatch_messages' ends in
%% `reactivate', which arms the transport once — so a partial frame here
%% simply waits for the rest to arrive from the socket.
open(internal, {drain, Bin}, St = #st{parser = P}) ->
    case ws_frame:parse(P, Bin) of
        {ok, Messages, P2} ->
            dispatch_messages(Messages, St#st{parser = P2}, open);
        {error, Reason, P2} ->
            abort_with_close(close_code_for(Reason), Reason,
                             St#st{parser = P2})
    end;
open(info, Msg, St = #st{transport_mod = TM, handle = H, parser = P,
                         handler_mod = HMod, handler_state = HState}) ->
    case TM:classify(Msg, H) of
        {ws_data, H, Bin} ->
            case ws_frame:parse(P, Bin) of
                {ok, Messages, P2} ->
                    dispatch_messages(Messages, St#st{parser = P2}, open);
                {error, Reason, P2} ->
                    abort_with_close(close_code_for(Reason), Reason,
                                     St#st{parser = P2})
            end;
        {ws_closed, H} ->
            {stop, normal, St};
        {ws_error, H, Reason} ->
            {stop, {transport_error, Reason}, St};
        ignore ->
            case maybe_handler_info(HMod, Msg, HState) of
                passthrough ->
                    keep_state_and_data;
                {ok, HState2} ->
                    {keep_state, St#st{handler_state = HState2}};
                {reply, Frames, HState2} ->
                    case send_frames(frames(Frames),
                                     St#st{handler_state = HState2}) of
                        {ok, St2} -> {keep_state, St2};
                        {error, Reason} -> {stop, Reason, St}
                    end;
                {stop, Reason, HState2} ->
                    {stop, Reason, St#st{handler_state = HState2}}
            end
    end;
open(cast, {send, Frames}, St) ->
    case send_frames(Frames, St) of
        {ok, St2} -> {keep_state, St2};
        {error, Reason} -> {stop, Reason, St}
    end;
open(cast, {close, Code, Reason}, St) ->
    initiate_close(Code, Reason, St);
open({timeout, idle}, idle, St) ->
    %% No inbound frame within `idle_timeout': close politely (1001).
    initiate_close(?WS_CLOSE_GOING_AWAY, <<>>, St).

%% --- closing state ----------------------------------------------------
%%
%% We have either sent or received a close frame. Keep draining until
%% the other direction completes, then exit.

closing(info, Msg, St = #st{transport_mod = TM, handle = H, parser = P}) ->
    case TM:classify(Msg, H) of
        {ws_data, H, Bin} ->
            case ws_frame:parse(P, Bin) of
                {ok, Messages, P2} ->
                    dispatch_messages(Messages, St#st{parser = P2}, closing);
                {error, _Reason, P2} ->
                    finish_close(St#st{parser = P2})
            end;
        {ws_closed, H} ->
            finish_close(St);
        {ws_error, H, _R} ->
            finish_close(St);
        ignore ->
            keep_state_and_data
    end;
closing(state_timeout, close, St) ->
    %% Peer never completed the close handshake within `close_timeout'.
    finish_close(St);
closing(cast, {send, _}, _St) ->
    keep_state_and_data;
closing(cast, {close, _C, _R}, _St) ->
    keep_state_and_data;
closing(_Et, _Msg, _St) ->
    keep_state_and_data.

%% --- shared dispatching ----------------------------------------------

dispatch_messages([], St, State) ->
    reactivate(St, State);
dispatch_messages([Msg | Rest], St, State) ->
    case handle_message(Msg, St, State) of
        {continue, St2, State2} ->
            dispatch_messages(Rest, St2, State2);
        {abort, Code, Why, St2} ->
            abort_with_close(Code, Why, St2);
        {stop, Reason, St2} ->
            {stop, Reason, St2}
    end.

handle_message(close, St, _State) ->
    handle_close_received(?WS_CLOSE_NORMAL, <<>>,
                          St#st{peer_close = remote});
handle_message({close, Code, Reason}, St, _State) ->
    handle_close_received(Code, Reason,
                          St#st{peer_close = {Code, Reason}});
handle_message({compressed, Kind, Payload},
               St = #st{deflate = #{inflate := Z,
                                    inflate_takeover := Takeover,
                                    max_inflate := Max}}, State) ->
    Inflated = try
        ws_deflate:inflate(Z, Takeover, Payload, Max)
    catch
        _:_ -> {error, bad_deflate}
    end,
    case {Inflated, Kind} of
        {{ok, Data}, text} ->
            case ws_frame:valid_utf8(Data) of
                true -> invoke_handler({text, Data}, St, State);
                false -> {abort, ?WS_CLOSE_INVALID_UTF8, invalid_utf8, St}
            end;
        {{ok, Data}, binary} ->
            invoke_handler({binary, Data}, St, State);
        {{error, {inflate_too_big, _}}, _} ->
            {abort, ?WS_CLOSE_TOO_BIG, message_too_big, St};
        {{error, _}, _} ->
            {abort, ?WS_CLOSE_PROTOCOL_ERROR, bad_deflate, St}
    end;
handle_message({ping, Payload}, St = #st{}, State) ->
    case send_frames([{pong, Payload}], St) of
        {ok, St2} ->
            %% also notify the handler (optional — keeps parity with cowboy)
            invoke_handler({ping, Payload}, St2, State);
        {error, Reason} ->
            {stop, Reason, St}
    end;
handle_message({pong, _} = M, St, State) ->
    invoke_handler(M, St, State);
handle_message({text, _} = M, St, State) ->
    invoke_handler(M, St, State);
handle_message({binary, _} = M, St, State) ->
    invoke_handler(M, St, State).

invoke_handler(Msg, St = #st{handler_mod = HMod, handler_state = HState}, _State) ->
    case HMod:handle_in(Msg, HState) of
        {ok, HState2} ->
            {continue, St#st{handler_state = HState2}, _State};
        {reply, Frames, HState2} ->
            case send_frames(frames(Frames), St#st{handler_state = HState2}) of
                {ok, St2} -> {continue, St2, _State};
                {error, Reason} -> {stop, Reason, St}
            end;
        {stop, Reason, HState2} ->
            {stop, Reason, St#st{handler_state = HState2}}
    end.

%% Peer sent us a close frame. Echo one back (once) and switch to
%% closing; let the peer close the TCP side.
handle_close_received(_Code, _Reason, St = #st{close_sent = true}) ->
    St2 = St#st{close_received = true},
    finish_close(St2);
handle_close_received(Code, _Reason, St) ->
    Echo = close_echo(Code),
    case send_frames([Echo], St) of
        {ok, St2} ->
            {stop, normal, St2#st{close_sent = true, close_received = true}};
        {error, Reason} ->
            {stop, Reason, St}
    end.

close_echo(Code) ->
    case ws_close:valid_on_wire(Code) of
        true -> {close, Code, <<>>};
        false -> {close, ?WS_CLOSE_PROTOCOL_ERROR, <<>>}
    end.

initiate_close(Code, Reason, St = #st{close_sent = false}) ->
    case send_frames([{close, Code, Reason}], St#st{close_sent = true}) of
        {ok, St2} -> {next_state, closing, St2, closing_actions(St2)};
        {error, R} -> {stop, R, St}
    end;
initiate_close(_C, _R, St) ->
    {keep_state, St}.

%% Idle timer: a generic named timer so it survives unrelated events and
%% is reset only when we choose (on inbound activity). `[]' disables it.
idle_action(#st{idle_timeout = infinity}) -> [];
idle_action(#st{idle_timeout = T})        -> [{{timeout, idle}, T, idle}].

%% Entering `closing': cancel the idle timer and arm the close-handshake
%% timeout so a silent peer cannot pin the session open forever.
closing_actions(#st{close_timeout = infinity}) ->
    [{{timeout, idle}, cancel}];
closing_actions(#st{close_timeout = T}) ->
    [{{timeout, idle}, cancel}, {state_timeout, T, close}].

abort_with_close(Code, Reason, St) ->
    _ = send_frames([{close, Code, io_code_reason(Reason)}], St),
    _ = (St#st.transport_mod):close(St#st.handle),
    {stop, normal, St#st{close_sent = true}}.

io_code_reason(invalid_utf8)   -> <<"invalid utf-8">>;
io_code_reason(message_too_big) -> <<"message too big">>;
io_code_reason(bad_close_code) -> <<"bad close code">>;
io_code_reason(_)               -> <<"protocol error">>.

close_code_for(invalid_utf8)    -> ?WS_CLOSE_INVALID_UTF8;
close_code_for(message_too_big) -> ?WS_CLOSE_TOO_BIG;
close_code_for(_)               -> ?WS_CLOSE_PROTOCOL_ERROR.

reactivate(St = #st{transport_mod = TM, handle = H}, StateName) ->
    _ = TM:activate(H),
    case StateName of
        open    -> {keep_state, St, idle_action(St)};
        closing -> {keep_state, St}
    end.

finish_close(St) ->
    _ = (St#st.transport_mod):close(St#st.handle),
    {stop, normal, St}.

maybe_handler_info(HMod, Msg, HState) ->
    case erlang:function_exported(HMod, handle_info, 2) of
        true -> HMod:handle_info(Msg, HState);
        false -> passthrough
    end.

frames(L) when is_list(L) -> L;
frames(F) -> [F].

send_frames([], St) -> {ok, St};
send_frames([F | Rest], St = #st{transport_mod = TM, handle = H, role = Role,
                                 deflate = Deflate}) ->
    Iolist = encode_out(F, Role, Deflate),
    case TM:send(H, Iolist) of
        ok -> send_frames(Rest, St);
        {error, _} = E -> E
    end.

%% With permessage-deflate negotiated, data frames go out compressed
%% (RSV1 set); control frames are never compressed (RFC 7692 §6).
encode_out({Kind, Payload}, Role, #{deflate := Z, deflate_takeover := Takeover})
        when Kind =:= text; Kind =:= binary ->
    Compressed = ws_deflate:deflate(Z, Takeover, Payload),
    ws_frame:encode_compressed({Kind, Compressed}, Role);
encode_out(F, Role, _Deflate) ->
    ws_frame:encode(F, Role).

%% Which context-takeover policy applies to each direction depends on
%% the role: the `client_*' parameters govern client-to-server frames,
%% the `server_*' parameters the reverse.
init_deflate_state(Negotiated, Role, ParserOpts) ->
    {InTakeover, OutTakeover} = case Role of
        server -> {maps:get(client_context_takeover, Negotiated),
                   maps:get(server_context_takeover, Negotiated)};
        client -> {maps:get(server_context_takeover, Negotiated),
                   maps:get(client_context_takeover, Negotiated)}
    end,
    #{inflate => ws_deflate:init_inflate(Negotiated, Role),
      deflate => ws_deflate:init_deflate(Negotiated, Role),
      inflate_takeover => InTakeover,
      deflate_takeover => OutTakeover,
      %% Inflated size is bounded by the same limit the parser applies
      %% to uncompressed messages, so a deflate bomb cannot bypass it.
      max_inflate => maps:get(max_message, ParserOpts,
                              ?WS_DEFAULT_MAX_MESSAGE_SIZE)}.

terminate(Reason, _StateName, #st{handler_mod = HMod, handler_state = HS,
                                  peer_close = PeerClose}) ->
    %% Surface the peer's close frame to the handler: {remote, Code,
    %% Reason} when it carried a status code, `remote' for a bare
    %% close. Other shutdowns pass the raw reason through.
    HReason = case PeerClose of
        undefined -> Reason;
        remote -> remote;
        {Code, Bin} -> {remote, Code, Bin}
    end,
    _ = case erlang:function_exported(HMod, terminate, 2) of
        true -> HMod:terminate(HReason, HS);
        false -> ok
    end,
    ok.

code_change(_OldVsn, State, Data, _Extra) ->
    {ok, State, Data}.
