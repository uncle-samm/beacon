-module(beacon_build_ffi).
-export([run_command/1]).

run_command(Cmd) ->
    Result = os:cmd(binary_to_list(Cmd)),
    unicode:characters_to_binary(Result).
