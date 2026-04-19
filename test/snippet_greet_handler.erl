%% === docs/guide.md "A minimal handler" ===
%% Copied verbatim from the guide. Any edit here must match the
%% guide, and vice versa; `ws_docs_snippets_SUITE' exercises this
%% module end-to-end to keep both in sync.
-module(snippet_greet_handler).
-behaviour(ws_handler).

-export([init/2, handle_in/2, handle_info/2, terminate/2]).

%% ---- required callbacks ---------------------------------------------

%% Called once, right after the peer's upgrade has been accepted and
%% before any inbound frame is dispatched. `Req` is whatever the
%% embedder supplied to `ws:accept/5` (method, path, headers, ...).
%% `Opts` is `HandlerOpts` from the same call.
init(_Req, Opts) ->
    {ok, Opts}.

%% Called for every complete message decoded from the peer. Return:
%%   {ok,     State}           — do nothing else
%%   {reply,  Frame | [Frame], State}  — send one or more frames
%%   {stop,   Reason,          State}  — terminate the session
handle_in({text, Data}, State) ->
    Reply = <<"hello ", Data/binary>>,
    {reply, {text, Reply}, State};
handle_in({binary, _}, State) ->
    {ok, State};
handle_in({ping, _}, State) ->
    %% The session already answered with a pong before calling us;
    %% this callback exists only so we can audit pings if we want to.
    {ok, State};
handle_in({pong, _}, State) ->
    {ok, State};
handle_in(close, State) ->
    {ok, State};
handle_in({close, _Code, _Reason}, State) ->
    {ok, State}.

%% Any Erlang message that arrives while the session is alive and is
%% not a transport event ends up here. Return a `{reply, ...}` to turn
%% a message into a WebSocket frame.
handle_info(_Msg, State) ->
    {ok, State}.

%% Called exactly once on session shutdown.
terminate(_Reason, _State) ->
    ok.
