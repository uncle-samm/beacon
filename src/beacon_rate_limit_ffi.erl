-module(beacon_rate_limit_ffi).
-export([new_table/1, increment/2, delete_key/2]).

new_table(Name) ->
    AtomName = binary_to_atom(<<"beacon_rl_", Name/binary>>, utf8),
    ets:new(AtomName, [set, public, named_table, {write_concurrency, true}]).

%% Atomically increment a counter. Returns the new value.
increment(Table, Key) ->
    try
        ets:update_counter(Table, Key, {2, 1})
    catch
        error:badarg ->
            %% Key doesn't exist — insert with count 1
            ets:insert(Table, {Key, 1}),
            1
    end.

delete_key(Table, Key) ->
    ets:delete(Table, Key),
    nil.
