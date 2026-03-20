-module(beacon_store_ffi).
-export([new_list_store/1, append/3, get_all/2, delete_key/2]).

%% SECURITY: Atom creation constraint.
%% Store names come from developer code at compile time, not from runtime user input.
%% The validate_atom_name/1 guard restricts names to alphanumeric/underscore/hyphen
%% (max 255 bytes), which bounds the atom table impact. Each distinct store name
%% creates exactly one atom. If runtime-controlled names are ever needed, switch
%% to binary_to_existing_atom or use an ETS-backed registry instead.

new_list_store(Name) ->
    case validate_atom_name(Name) of
        ok ->
            AtomName = binary_to_atom(<<"beacon_ls_", Name/binary>>, utf8),
            ets:new(AtomName, [bag, public, named_table, {read_concurrency, true}]);
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

append(Store, Key, Value) ->
    ets:insert(Store, {Key, Value}),
    nil.

get_all(Store, Key) ->
    [V || {_, V} <- ets:lookup(Store, Key)].

delete_key(Store, Key) ->
    ets:delete(Store, Key),
    nil.
