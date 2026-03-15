-module(beacon_ets_ffi).
-export([new_table/1, put/3, get/2, delete/2, count/1]).

%% Create a new ETS table. Returns the table reference.
%% Using `set` type with `public` access so any process can read/write.
new_table(Name) ->
    AtomName = binary_to_atom(Name, utf8),
    ets:new(AtomName, [set, public, named_table, {read_concurrency, true}]).

%% Store a key-value pair in the ETS table.
put(Table, Key, Value) ->
    ets:insert(Table, {Key, Value}),
    nil.

%% Retrieve a value from the ETS table. Returns {ok, Value} or {error, nil}.
get(Table, Key) ->
    case ets:lookup(Table, Key) of
        [{_, Value}] -> {ok, Value};
        [] -> {error, nil}
    end.

%% Delete a key from the ETS table.
delete(Table, Key) ->
    ets:delete(Table, Key),
    nil.

%% Count the number of entries in the ETS table.
count(Table) ->
    ets:info(Table, size).
