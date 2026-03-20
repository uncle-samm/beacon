-module(beacon_build_ffi).
-export([run_command/1, string_to_bytes/1, bytes_to_string/1]).

%% SECURITY: os:cmd runs commands via the system shell. All directory paths
%% concatenated into commands MUST be wrapped in single quotes on the caller side
%% (build.gleam) to prevent shell injection. Gleam project paths are controlled
%% by the developer (not user input), but quoting prevents accidental breakage
%% from paths with spaces or special characters.
run_command(Cmd) ->
    Result = os:cmd(binary_to_list(Cmd)),
    unicode:characters_to_binary(Result).

%% Convert a binary string to a list of byte values.
%% Used by the AST extractor to slice source text by byte offsets.
string_to_bytes(Bin) when is_binary(Bin) ->
    binary_to_list(Bin).

%% Convert a list of byte values back to a binary string.
bytes_to_string(Bytes) when is_list(Bytes) ->
    list_to_binary(Bytes).
