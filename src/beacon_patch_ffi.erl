-module(beacon_patch_ffi).
-export([diff_json/2, apply_json_ops/2, is_empty_ops/1, merge_ops_json/1]).

%% Diff two JSON strings and produce patch operations.
%% Returns a JSON-encoded string of the ops array.
%% Uses OTP 28's json:decode/1 and json:encode/1.
-spec diff_json(binary(), binary()) -> binary().
diff_json(OldJson, NewJson) ->
    Old = json:decode(OldJson),
    New = json:decode(NewJson),
    Ops = diff_values(Old, New, <<>>),
    iolist_to_binary(json:encode(Ops)).

%% Apply patch operations (JSON string) to a model JSON string.
%% Returns {ok, NewJsonString} or {error, Reason}.
-spec apply_json_ops(binary(), binary()) -> {ok, binary()} | {error, binary()}.
apply_json_ops(ModelJson, OpsJson) ->
    try
        Model = json:decode(ModelJson),
        Ops = json:decode(OpsJson),
        NewModel = apply_ops_list(Model, Ops),
        {ok, iolist_to_binary(json:encode(NewModel))}
    catch
        _Class:Reason ->
            ReasonBin = unicode:characters_to_binary(
                io_lib:format("Patch apply failed: ~p", [Reason])
            ),
            {error, ReasonBin}
    end.

%% Check if an ops JSON string represents an empty ops array.
-spec is_empty_ops(binary()) -> boolean().
is_empty_ops(OpsJson) ->
    case json:decode(OpsJson) of
        [] -> true;
        _ -> false
    end.

%% === Diff Engine ===

%% Diff two decoded JSON values at a given path prefix.
-spec diff_values(term(), term(), binary()) -> list().
diff_values(Old, New, _Path) when Old =:= New ->
    [];
diff_values(Old, New, Path) when is_map(Old), is_map(New) ->
    diff_maps(Old, New, Path);
diff_values(Old, New, Path) when is_list(Old), is_list(New) ->
    diff_arrays(Old, New, Path);
diff_values(_Old, New, Path) ->
    [#{<<"op">> => <<"replace">>, <<"path">> => Path, <<"value">> => New}].

%% Diff two maps, producing ops for changed/added/removed keys.
-spec diff_maps(map(), map(), binary()) -> list().
diff_maps(Old, New, BasePath) ->
    %% Removed keys
    RemovedOps = maps:fold(fun(Key, _Val, Acc) ->
        case maps:is_key(Key, New) of
            true -> Acc;
            false ->
                Path = <<BasePath/binary, $/, Key/binary>>,
                [#{<<"op">> => <<"remove">>, <<"path">> => Path} | Acc]
        end
    end, [], Old),
    %% Added/changed keys
    ChangedOps = maps:fold(fun(Key, NewVal, Acc) ->
        Path = <<BasePath/binary, $/, Key/binary>>,
        case maps:find(Key, Old) of
            error ->
                %% New key
                [#{<<"op">> => <<"replace">>, <<"path">> => Path, <<"value">> => NewVal} | Acc];
            {ok, OldVal} ->
                diff_values(OldVal, NewVal, Path) ++ Acc
        end
    end, [], New),
    RemovedOps ++ ChangedOps.

%% Diff two arrays. Detects append pattern (common prefix + new items at end).
-spec diff_arrays(list(), list(), binary()) -> list().
diff_arrays(Old, New, Path) ->
    OldLen = length(Old),
    NewLen = length(New),
    case NewLen > OldLen of
        true ->
            %% Check for append: new list starts with all old items
            {Prefix, Suffix} = lists:split(OldLen, New),
            case Prefix =:= Old of
                true ->
                    %% Pure append — only send the new items
                    [#{<<"op">> => <<"append">>, <<"path">> => Path, <<"value">> => Suffix}];
                false ->
                    %% Not a simple append — replace entire array
                    [#{<<"op">> => <<"replace">>, <<"path">> => Path, <<"value">> => New}]
            end;
        false ->
            case Old =:= New of
                true -> [];
                false ->
                    %% Shorter or same length but different — replace
                    [#{<<"op">> => <<"replace">>, <<"path">> => Path, <<"value">> => New}]
            end
    end.

%% === Apply Engine ===

%% Apply a list of ops to a model.
-spec apply_ops_list(term(), list()) -> term().
apply_ops_list(Model, []) ->
    Model;
apply_ops_list(Model, [Op | Rest]) ->
    NewModel = apply_single_op(Model, Op),
    apply_ops_list(NewModel, Rest).

%% Apply a single op.
-spec apply_single_op(term(), map()) -> term().
apply_single_op(Model, #{<<"op">> := <<"replace">>, <<"path">> := Path, <<"value">> := Value}) ->
    set_at_path(Model, parse_path(Path), Value);
apply_single_op(Model, #{<<"op">> := <<"append">>, <<"path">> := Path, <<"value">> := Items}) ->
    append_at_path(Model, parse_path(Path), Items);
apply_single_op(Model, #{<<"op">> := <<"remove">>, <<"path">> := Path}) ->
    remove_at_path(Model, parse_path(Path));
apply_single_op(Model, _UnknownOp) ->
    Model.

%% Parse a JSON path like "/foo/bar" into ["foo", "bar"].
%% Empty path "" or "/" means root.
-spec parse_path(binary()) -> list(binary()).
parse_path(<<>>) -> [];
parse_path(<<"/">>) -> [];
parse_path(Path) ->
    %% Split on "/" and remove empty segments
    Parts = binary:split(Path, <<"/">>, [global]),
    [P || P <- Parts, P =/= <<>>].

%% Set a value at a path in a nested map structure.
-spec set_at_path(term(), list(binary()), term()) -> term().
set_at_path(_Model, [], Value) ->
    Value;
set_at_path(Model, [Key], Value) when is_map(Model) ->
    maps:put(Key, Value, Model);
set_at_path(Model, [Key | Rest], Value) when is_map(Model) ->
    Inner = maps:get(Key, Model, #{}),
    maps:put(Key, set_at_path(Inner, Rest, Value), Model);
set_at_path(Model, _Path, _Value) ->
    Model.

%% Append items to an array at a path.
-spec append_at_path(term(), list(binary()), list()) -> term().
append_at_path(Model, [], Items) when is_list(Model) ->
    Model ++ Items;
append_at_path(Model, [Key], Items) when is_map(Model) ->
    case maps:get(Key, Model, []) of
        OldList when is_list(OldList) ->
            maps:put(Key, OldList ++ Items, Model);
        _ ->
            Model
    end;
append_at_path(Model, [Key | Rest], Items) when is_map(Model) ->
    Inner = maps:get(Key, Model, #{}),
    maps:put(Key, append_at_path(Inner, Rest, Items), Model);
append_at_path(Model, _Path, _Items) ->
    Model.

%% Remove a key at a path.
-spec remove_at_path(term(), list(binary())) -> term().
remove_at_path(Model, []) ->
    Model;
remove_at_path(Model, [Key]) when is_map(Model) ->
    maps:remove(Key, Model);
remove_at_path(Model, [Key | Rest]) when is_map(Model) ->
    case maps:find(Key, Model) of
        {ok, Inner} ->
            maps:put(Key, remove_at_path(Inner, Rest), Model);
        error ->
            Model
    end;
remove_at_path(Model, _Path) ->
    Model.

%% Merge multiple JSON ops arrays into a single array.
%% Each input is a JSON-encoded string like "[{...}]".
-spec merge_ops_json(list(binary())) -> binary().
merge_ops_json(OpsList) ->
    AllOps = lists:flatmap(fun(OpsJson) ->
        json:decode(OpsJson)
    end, OpsList),
    iolist_to_binary(json:encode(AllOps)).
