# erlang_ws examples

Three self-contained examples, each a single module.

- `echo_server.erl` — a trivial echo server. Any text / binary frame
  is reflected back unchanged.
- `echo_client.erl` — a synchronous client that sends a single text
  frame and waits for the echo.
- `chat_server.erl` — a broadcast chat server. Text frames received
  on any connection are delivered as text frames on every other open
  connection (uses OTP `pg`).

All three modules compile together with the library under the test
profile:

    rebar3 as test compile

The shared code path after compile is:

    _build/test/lib/ws/ebin        — the library
    _build/test/lib/ws/examples    — the example modules

Run the echo server:

    erl -pa _build/test/lib/ws/ebin _build/test/lib/ws/examples \
        -s echo_server run -noshell

Run the chat server on port 8081:

    erl -pa _build/test/lib/ws/ebin _build/test/lib/ws/examples \
        -s chat_server run -noshell

The examples are covered by the `ws_examples_SUITE` Common Test suite.
Running `rebar3 ct` boots each example server on an ephemeral port,
exercises it with `ws:connect/2`, then tears it down.
