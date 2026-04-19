%% @doc Close-code classification and validation (RFC 6455 §7.4).
%%
%% 1000..1003, 1007..1011 are defined.
%% 1004 is reserved; 1005, 1006, 1015 MUST NOT appear on the wire.
%% 3000..3999 are reserved for registration.
%% 4000..4999 are free for application use.
-module(ws_close).

-export([valid_on_wire/1]).
-export([reason_name/1]).

-include("../include/ws.hrl").

-type code() :: 1000..4999.
-export_type([code/0]).

%% @doc True if Code is allowed to appear in a close frame on the wire.
-spec valid_on_wire(integer()) -> boolean().
valid_on_wire(Code) when is_integer(Code) ->
    if
        Code < 1000 -> false;
        Code =:= 1004 -> false;
        Code =:= 1005 -> false;
        Code =:= 1006 -> false;
        Code =:= 1015 -> false;
        Code =< 1011 -> true;
        Code < 3000 -> false;
        Code =< 4999 -> true;
        true -> false
    end;
valid_on_wire(_) ->
    false.

%% @doc Human-readable label for a standard close code. Returns `undefined'
%% for application-range codes the library does not know about.
-spec reason_name(integer()) -> atom().
reason_name(?WS_CLOSE_NORMAL)          -> normal;
reason_name(?WS_CLOSE_GOING_AWAY)      -> going_away;
reason_name(?WS_CLOSE_PROTOCOL_ERROR)  -> protocol_error;
reason_name(?WS_CLOSE_UNSUPPORTED)     -> unsupported_data;
reason_name(?WS_CLOSE_NO_STATUS)       -> no_status;
reason_name(?WS_CLOSE_ABNORMAL)        -> abnormal;
reason_name(?WS_CLOSE_INVALID_UTF8)    -> invalid_utf8;
reason_name(?WS_CLOSE_POLICY)          -> policy_violation;
reason_name(?WS_CLOSE_TOO_BIG)         -> message_too_big;
reason_name(?WS_CLOSE_EXT_NEGOTIATION) -> extension_required;
reason_name(?WS_CLOSE_INTERNAL_ERROR)  -> internal_error;
reason_name(?WS_CLOSE_TLS_HANDSHAKE)   -> tls_handshake;
reason_name(_)                         -> undefined.
