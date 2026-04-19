# Errors and close codes

This page lists every failure mode the library can surface, together
with what the library does about it and what you can do about it as
an operator.

- [Parser errors](#parser-errors)
- [Close codes (RFC 6455 §7.4)](#close-codes-rfc-6455-74)
- [Handshake errors (HTTP/1.1)](#handshake-errors-http11)
- [Handshake errors (HTTP/2 / HTTP/3)](#handshake-errors-http2--http3)
- [Transport errors](#transport-errors)

## Parser errors

`ws_frame:parse/2` returns `{error, Reason, Parser}`. The session
turns each one into the mandated RFC 6455 close frame, sends it, and
shuts the socket down. Your handler's `terminate/2` receives
`normal`.

| `Reason`          | Close code | Meaning                                    |
|-------------------|:----------:|--------------------------------------------|
| `protocol_error`  | 1002       | RSV bits set with no extension, bad opcode, non-minimal length encoding, control frame > 125 bytes or fragmented, mask bit wrong for the role, continuation frame without an open fragment, etc. |
| `invalid_utf8`    | 1007       | Invalid UTF-8 in a text frame or in a close-frame reason. |
| `message_too_big` | 1009       | Single frame over `max_frame`, or accumulated fragments over `max_message`. |
| `bad_close_code`  | 1002       | Close frame carrying a reserved or undefined code (1004, 1005, 1006, 1012–2999, 5000+). |

## Close codes (RFC 6455 §7.4)

The `ws_close` module gates which codes are legal on the wire.

```erlang
1> ws_close:valid_on_wire(1000).
true
2> ws_close:valid_on_wire(1005).
false                             %% reserved: "no status"
3> ws_close:reason_name(1009).
message_too_big
```

| Code       | Name                  | Source                    |
|------------|-----------------------|---------------------------|
| 1000       | normal                | either peer               |
| 1001       | going_away            | either peer               |
| 1002       | protocol_error        | session on protocol violation |
| 1003       | unsupported_data      | handler                   |
| 1004       | reserved              | **never on the wire**     |
| 1005       | no_status             | local-only                |
| 1006       | abnormal              | local-only                |
| 1007       | invalid_utf8          | session on bad UTF-8      |
| 1008       | policy_violation      | handler                   |
| 1009       | message_too_big       | session on size limit     |
| 1010       | extension_required    | client                    |
| 1011       | internal_error        | server                    |
| 1015       | tls_handshake         | **never on the wire**     |
| 3000–3999  | registered            | application               |
| 4000–4999  | private               | application               |

## Handshake errors (HTTP/1.1)

`ws_h1_upgrade:validate_request/1,2` returns `{error, Reason}` on any
of these:

| `Reason`                      | Meaning                                                          |
|-------------------------------|------------------------------------------------------------------|
| `missing_upgrade_header`      | No `Upgrade:` at all.                                            |
| `{invalid_upgrade, Value}`    | `Upgrade:` does not list `websocket`.                            |
| `missing_connection_header`   | No `Connection:` at all.                                         |
| `{invalid_connection, Value}` | `Connection:` does not list `upgrade`.                           |
| `{unsupported_version, V}`    | `Sec-WebSocket-Version` is not `13`.                             |
| `missing_sec_websocket_key`   | Header absent.                                                   |
| `bad_sec_websocket_key`       | Header present but not 16 bytes once base64-decoded.             |
| `no_acceptable_subprotocol`   | `required_subprotocols` was set and none of them was offered.    |

`ws_h1_upgrade:validate_response/2` returns `{error, Reason}` for the
client-side validation of a 101:

| `Reason`                     | Meaning                                                |
|------------------------------|--------------------------------------------------------|
| `{unexpected_status, N}`     | Status line was not 101.                               |
| `missing_upgrade_header`     | Response missing `Upgrade: websocket`.                 |
| `missing_connection_header`  | Response missing `Connection: upgrade`.                |
| `missing_sec_websocket_accept` | Response missing `Sec-WebSocket-Accept`.             |

Additionally `ws_client:connect/2` returns
`{error, sec_websocket_accept_mismatch}` if the computed accept
value does not match the server's.

## Handshake errors (HTTP/2 / HTTP/3)

`ws_h2_upgrade:validate_request/1,2` (and its `ws_h3_upgrade` alias):

| `Reason`                      | Meaning                                                  |
|-------------------------------|----------------------------------------------------------|
| `wrong_method`                | `:method` is not `CONNECT`.                              |
| `wrong_protocol`              | `:protocol` is not `websocket`.                          |
| `missing_scheme`              | `:scheme` not present.                                   |
| `missing_authority`           | `:authority` not present.                                |
| `missing_path`                | `:path` not present.                                     |
| `no_acceptable_subprotocol`   | `required_subprotocols` was set and none matched.        |

`ws_h2_upgrade:client_request/4` returns
`{error, peer_does_not_allow_connect_protocol}` if you try to build
an extended-CONNECT request against a peer that did not advertise
`SETTINGS_ENABLE_CONNECT_PROTOCOL = 1`.

## Transport errors

Transport I/O errors propagate through the session as
`{stop, {transport_error, Reason}, State}` — the handler's
`terminate/2` is called with that tuple. The most common are
`closed` (peer went away), `timeout` (only possible during the
client handshake), and `{tls_alert, _}` when the TLS handshake
fails.

If a custom transport does not implement `recv/2` and the client
needs it, `ws_client:connect/2` returns
`{error, {transport_does_not_support_recv, Mod}}`.
