-module(beacon_csrf_ffi).
-export([new_store/1, put_token/3, get_token/2, delete_token/2]).

new_store(Name) ->
    AtomName = binary_to_atom(<<"beacon_csrf_", Name/binary>>, utf8),
    ets:new(AtomName, [set, public, named_table]).

put_token(Store, Key, Value) ->
    ets:insert(Store, {Key, Value}),
    nil.

get_token(Store, Key) ->
    case ets:lookup(Store, Key) of
        [{_, Value}] -> {ok, Value};
        [] -> {error, nil}
    end.

delete_token(Store, Key) ->
    ets:delete(Store, Key),
    nil.
