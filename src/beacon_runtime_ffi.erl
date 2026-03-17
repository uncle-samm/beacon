-module(beacon_runtime_ffi).
-export([rescue/1, store_redirect_target/1, get_redirect_target/0, try_load_codec_encoder/0]).

%% Execute a function, catching any exception.
%% Returns {ok, Result} on success, {error, Reason} on failure.
rescue(Fun) ->
    try
        Result = Fun(),
        {ok, Result}
    catch
        _Class:Reason ->
            ReasonBin = unicode:characters_to_binary(
                io_lib:format("~p", [Reason])
            ),
            {error, ReasonBin}
    end.

%% Store redirect target in process dictionary for current effect execution.
store_redirect_target(Subject) ->
    erlang:put(beacon_redirect_target, Subject),
    nil.

%% Get redirect target from process dictionary.
get_redirect_target() ->
    case erlang:get(beacon_redirect_target) of
        undefined -> none;
        Subject -> {some, Subject}
    end.

%% Auto-discover beacon_codec module and return its encode_model function.
%% Returns {ok, Fun} if the module exists and exports encode_model/1,
%% or {error, nil} if not found.
try_load_codec_encoder() ->
    case code:ensure_loaded(beacon_codec) of
        {module, beacon_codec} ->
            case erlang:function_exported(beacon_codec, encode_model, 1) of
                true ->
                    {ok, fun beacon_codec:encode_model/1};
                false ->
                    {error, nil}
            end;
        _ ->
            {error, nil}
    end.
