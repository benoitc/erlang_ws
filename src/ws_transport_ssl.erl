%% @doc `ws_transport' implementation over OTP `ssl'. Used by the
%% client for `wss://' URLs. Mirrors `ws_transport_gen_tcp' in every
%% respect except the module calls and message shape.
-module(ws_transport_ssl).
-behaviour(ws_transport).

-export([send/2, activate/1, close/1, controlling_process/2, peername/1]).
-export([classify/2, recv/2]).

send(Sock, Data) ->
    ssl:send(Sock, Data).

activate(Sock) ->
    ssl:setopts(Sock, [{active, once}]).

close(Sock) ->
    ssl:close(Sock).

controlling_process(Sock, Pid) ->
    ssl:controlling_process(Sock, Pid).

peername(Sock) ->
    ssl:peername(Sock).

classify({ssl, Sock, Data}, Sock) ->        {ws_data, Sock, Data};
classify({ssl_closed, Sock}, Sock) ->       {ws_closed, Sock};
classify({ssl_error, Sock, Reason}, Sock) -> {ws_error, Sock, Reason};
classify(_Other, _Sock) ->                   ignore.

recv(Sock, Timeout) ->
    ssl:recv(Sock, 0, Timeout).
