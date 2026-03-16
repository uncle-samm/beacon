-module(beacon_session_ffi).
-export([session_ets_new/1, session_ets_put/3, session_ets_get/2, session_ets_delete/2, generate_session_id/0]).

session_ets_new(Name) ->
    TableName = binary_to_atom(<<"beacon_session_", Name/binary>>, utf8),
    ets:new(TableName, [set, public, named_table, {read_concurrency, true}]).

session_ets_put(Table, Key, Value) ->
    ets:insert(Table, {Key, Value}),
    nil.

session_ets_get(Table, Key) ->
    case ets:lookup(Table, Key) of
        [{_, Value}] -> {ok, Value};
        [] -> {error, nil}
    end.

session_ets_delete(Table, Key) ->
    ets:delete(Table, Key),
    nil.

generate_session_id() ->
    Bytes = crypto:strong_rand_bytes(32),
    Base = base64:encode(Bytes),
    %% Make URL-safe
    Safe = binary:replace(binary:replace(binary:replace(Base, <<"+">>, <<"-">>, [global]), <<"/">>, <<"_">>, [global]), <<"=">>, <<>>, [global]),
    Safe.
