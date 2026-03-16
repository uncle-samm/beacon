-module(beacon_handler_ffi).
-export([pd_set/2, pd_get/1]).

pd_set(Key, Value) ->
    put(Key, Value),
    nil.

pd_get(Key) ->
    case get(Key) of
        undefined -> {error, nil};
        Value -> {ok, Value}
    end.
