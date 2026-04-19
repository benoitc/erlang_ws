-module(ws_close_tests).
-include_lib("eunit/include/eunit.hrl").

valid_on_wire_accepts_registered_test_() ->
    [?_assert(ws_close:valid_on_wire(C))
     || C <- [1000, 1001, 1002, 1003, 1007, 1008, 1009, 1010, 1011,
              3000, 3999, 4000, 4999]].

valid_on_wire_rejects_reserved_test_() ->
    [?_assertNot(ws_close:valid_on_wire(C))
     || C <- [0, 999, 1004, 1005, 1006, 1012, 1013, 1014, 1015, 1016,
              2999, 5000, -1, 65536, not_a_code]].

reason_name_known_test() ->
    ?assertEqual(normal,           ws_close:reason_name(1000)),
    ?assertEqual(going_away,       ws_close:reason_name(1001)),
    ?assertEqual(protocol_error,   ws_close:reason_name(1002)),
    ?assertEqual(unsupported_data, ws_close:reason_name(1003)),
    ?assertEqual(invalid_utf8,     ws_close:reason_name(1007)),
    ?assertEqual(message_too_big,  ws_close:reason_name(1009)),
    ?assertEqual(internal_error,   ws_close:reason_name(1011)).

reason_name_unknown_test() ->
    ?assertEqual(undefined, ws_close:reason_name(3000)),
    ?assertEqual(undefined, ws_close:reason_name(4321)).
