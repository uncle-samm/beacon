-module(beacon_session_ffi).
-export([session_ets_new/1, session_ets_put/3, session_ets_get/2, session_ets_delete/2, generate_session_id/0]).

session_ets_new(Name) ->
    case validate_atom_name(Name) of
        ok ->
            TableName = binary_to_atom(<<"beacon_session_", Name/binary>>, utf8),
            ets:new(TableName, [set, public, named_table, {read_concurrency, true}]);
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
