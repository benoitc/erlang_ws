%% @doc Reference `ws_transport' implementation over plain `gen_tcp'.
%%
%% Used by the CT test suite as the embedder stand-in. Translates
%% `tcp' / `tcp_closed' / `tcp_error' messages into the canonical
%% `ws_*' messages the session consumes.
-module(ws_transport_gen_tcp).
-behaviour(ws_transport).

-export([send/2, activate/1, close/1, controlling_process/2, peername/1]).
-export([classify/2, recv/2]).

send(Sock, Data) ->
    gen_tcp:send(Sock, Data).

activate(Sock) ->
    inet:setopts(Sock, [{active, once}]).

close(Sock) ->
    gen_tcp:close(Sock).

controlling_process(Sock, Pid) ->
    gen_tcp:controlling_process(Sock, Pid).

peername(Sock) ->
    inet:peername(Sock).

classify({tcp, Sock, Data}, Sock) ->        {ws_data, Sock, Data};
classify({tcp_closed, Sock}, Sock) ->       {ws_closed, Sock};
classify({tcp_error, Sock, Reason}, Sock) -> {ws_error, Sock, Reason};
classify(_Other, _Sock) ->                   ignore.

recv(Sock, Timeout) ->
    gen_tcp:recv(Sock, 0, Timeout).
