-module(beacon_rate_limit_ffi).
-export([new_table/1, increment/2, delete_key/2]).

new_table(Name) ->
    case validate_atom_name(Name) of
        ok ->
            AtomName = binary_to_atom(<<"beacon_rl_", Name/binary>>, utf8),
            ets:new(AtomName, [set, public, named_table, {write_concurrency, true}]);
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
