-module(beacon_csrf_ffi).
-export([new_store/1, put_token/3, get_token/2, delete_token/2]).

%% SECURITY: Atom creation constraint.
%% CSRF store names come from developer code at compile time, not from runtime
%% user input. The validate_atom_name/1 guard restricts names to alphanumeric/
%% underscore/hyphen (max 255 bytes). Each distinct store creates one atom.

new_store(Name) ->
    case validate_atom_name(Name) of
        ok ->
            AtomName = binary_to_atom(<<"beacon_csrf_", Name/binary>>, utf8),
            ets:new(AtomName, [set, public, named_table]);
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
