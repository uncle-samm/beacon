-module(beacon_store_ffi).
-export([new_list_store/1, append/3, get_all/2, delete_key/2]).

new_list_store(Name) ->
    AtomName = binary_to_atom(<<"beacon_ls_", Name/binary>>, utf8),
    ets:new(AtomName, [bag, public, named_table, {read_concurrency, true}]).

append(Store, Key, Value) ->
    ets:insert(Store, {Key, Value}),
    nil.

get_all(Store, Key) ->
    [V || {_, V} <- ets:lookup(Store, Key)].

delete_key(Store, Key) ->
    ets:delete(Store, Key),
    nil.
