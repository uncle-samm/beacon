-module(beacon_build_ffi).
-export([run_command/1, string_to_bytes/1, bytes_to_string/1, is_source_newer_than_manifest/0]).

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

%% Check if the beacon client FFI source is newer than the built manifest.
%% Returns true if rebuild is needed, false if bundle is fresh.
%% Finds the beacon_client_ffi.mjs source via code:priv_dir or relative path.
is_source_newer_than_manifest() ->
    ManifestPath = "priv/static/beacon_client.manifest",
    %% Find the beacon client source — try code:priv_dir first, then relative paths
    SourcePath = find_client_source(),
    case {SourcePath, file:read_file_info(ManifestPath)} of
        {none, _} ->
            %% Can't find source — assume fresh (don't rebuild if we can't verify)
            false;
        {_, {error, _}} ->
            %% No manifest — need to build
            true;
        {{ok, Src}, {ok, ManifestInfo}} ->
            case file:read_file_info(Src) of
                {ok, SrcInfo} ->
                    %% Compare modification times
                    element(6, SrcInfo) > element(6, ManifestInfo);
                {error, _} ->
                    false
            end
    end.

find_client_source() ->
    %% Try multiple locations where beacon_client_ffi.mjs might be
    Candidates = [
        "beacon_client/src/beacon_client_ffi.mjs",
        "vendor/beacon/beacon_client/src/beacon_client_ffi.mjs"
    ] ++ case code:priv_dir(beacon) of
        {error, _} -> [];
        PrivDir ->
            [filename:join([filename:dirname(PrivDir), "beacon_client", "src", "beacon_client_ffi.mjs"])]
    end,
    find_existing(Candidates).

find_existing([]) -> none;
find_existing([Path | Rest]) ->
    case filelib:is_file(Path) of
        true -> {ok, Path};
        false -> find_existing(Rest)
    end.
