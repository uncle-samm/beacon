-module(beacon_ets_ffi).
-export([new_table/1, put/3, get/2, delete/2, count/1]).

%% SECURITY: Atom creation constraint.
%% Table names come from developer code at compile time, not from runtime user input.
%% The validate_atom_name/1 guard restricts names to alphanumeric/underscore/hyphen
%% (max 255 bytes). Each distinct table creates one atom.

%% Create a new ETS table. Returns the table reference.
%% Using `set` type with `public` access so any process can read/write.
new_table(Name) ->
    case validate_atom_name(Name) of
        ok ->
            AtomName = binary_to_atom(Name, utf8),
            ets:new(AtomName, [set, public, named_table, {read_concurrency, true}]);
        {error, Reason} ->
            error(Reason)
    end.

%% Validate that a name is safe for atom conversion.
%% Max 255 bytes, alphanumeric + underscore + hyphen only (no spaces, no special chars).
%% This prevents atom table exhaustion from arbitrary user-controlled input.
validate_atom_name(Name) when byte_size(Name) > 255 ->
    {error, <<"Name too long (max 255 bytes)">>};
validate_atom_name(Name) ->
    case re:run(Name, <<"^[a-zA-Z0-9_-]+$">>) of
        {match, _} -> ok;
        nomatch -> {error, <<"Invalid name: must be alphanumeric, underscore, or hyphen">>}
    end.

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
