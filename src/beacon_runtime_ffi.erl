-module(beacon_runtime_ffi).
-export([rescue/1]).

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
