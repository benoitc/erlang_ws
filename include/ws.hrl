%% @doc Shared records, macros and limits for the ws application.

%% RFC 6455 §5.2 opcodes.
-define(WS_OP_CONT,   16#0).
-define(WS_OP_TEXT,   16#1).
-define(WS_OP_BINARY, 16#2).
-define(WS_OP_CLOSE,  16#8).
-define(WS_OP_PING,   16#9).
-define(WS_OP_PONG,   16#A).

%% GUID from RFC 6455 §1.3, used to derive Sec-WebSocket-Accept.
-define(WS_GUID, <<"258EAFA5-E914-47DA-95CA-C5AB0DC85B11">>).

%% RFC 6455 §7.4 defined close codes. 1005/1006/1015 are reserved and
%% MUST NOT appear on the wire.
-define(WS_CLOSE_NORMAL,          1000).
-define(WS_CLOSE_GOING_AWAY,      1001).
-define(WS_CLOSE_PROTOCOL_ERROR,  1002).
-define(WS_CLOSE_UNSUPPORTED,     1003).
-define(WS_CLOSE_NO_STATUS,       1005).
-define(WS_CLOSE_ABNORMAL,        1006).
-define(WS_CLOSE_INVALID_UTF8,    1007).
-define(WS_CLOSE_POLICY,          1008).
-define(WS_CLOSE_TOO_BIG,         1009).
-define(WS_CLOSE_EXT_NEGOTIATION, 1010).
-define(WS_CLOSE_INTERNAL_ERROR,  1011).
-define(WS_CLOSE_TLS_HANDSHAKE,   1015).

%% Default limits enforced by the frame decoder. Embedders may
%% override via session options.
-define(WS_DEFAULT_MAX_FRAME_SIZE,   (16 * 1024 * 1024)). %% 16 MiB
-define(WS_DEFAULT_MAX_MESSAGE_SIZE, (64 * 1024 * 1024)). %% 64 MiB

%% Session timeouts (ms). `idle_timeout' bounds inactivity on an open
%% connection (reset on each inbound frame); `close_timeout' bounds the
%% wait for the peer's close echo once we have sent a close. Both accept
%% `infinity' to disable. Set via session options.
-define(WS_DEFAULT_IDLE_TIMEOUT,  60000).
-define(WS_DEFAULT_CLOSE_TIMEOUT, 5000).

%% Parser state carried between frame decode calls. Holds partial
%% bytes and the current fragmented-message accumulator.
-record(ws_parser, {
    role      = server  :: server | client, %% controls mask-required check
    buffer    = <<>>    :: binary(),
    frag_op   = undefined :: text | binary | undefined,
    frag_acc  = []      :: [binary()],
    frag_size = 0       :: non_neg_integer(),
    utf8_state = 0      :: non_neg_integer(), %% UTF-8 DFA state (text frames)
    max_frame   = ?WS_DEFAULT_MAX_FRAME_SIZE   :: pos_integer(),
    max_message = ?WS_DEFAULT_MAX_MESSAGE_SIZE :: pos_integer()
}).
