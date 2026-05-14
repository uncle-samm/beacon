-module(beacon_build_ffi).
-export([string_to_bytes/1, bytes_to_string/1,
         run_program/3, absolute_path/1, generate_safe_hash/0,
         is_any_source_newer_than_manifest/1, is_any_source_newer_than/2]).

%% Run a program without invoking a shell. This prevents build-time command
%% injection through project paths or path dependencies.
run_program(Cwd0, Program0, Args0) ->
    Cwd = binary_to_list(Cwd0),
    Program = binary_to_list(Program0),
    Args = [binary_to_list(Arg) || Arg <- Args0],
    case os:find_executable(Program) of
        false ->
            {error, unicode:characters_to_binary(["Executable not found: ", Program])};
        Executable ->
            try open_port(
                    {spawn_executable, Executable},
                    [
                        {cd, Cwd},
                        {args, Args},
                        exit_status,
                        use_stdio,
                        stderr_to_stdout,
                        binary
                    ]
                ) of
                Port -> collect_port_output(Port, [])
            catch
                error:Reason ->
                    {error, unicode:characters_to_binary(
                        io_lib:format("Failed to start ~s in ~s: ~p", [Program, Cwd, Reason])
                    )}
            end
    end.

collect_port_output(Port, Acc) ->
    receive
        {Port, {data, Data}} ->
            collect_port_output(Port, [Data | Acc]);
        {Port, {exit_status, 0}} ->
            {ok, iolist_to_binary(lists:reverse(Acc))};
        {Port, {exit_status, Status}} ->
            Output = iolist_to_binary(lists:reverse(Acc)),
            {error, unicode:characters_to_binary([
                Output,
                "\nExit status: ",
                integer_to_list(Status)
            ])}
    end.

absolute_path(Path0) ->
    Path = binary_to_list(Path0),
    {ok, unicode:characters_to_binary(filename:absname(Path))}.

generate_safe_hash() ->
    Seed = term_to_binary({erlang:monotonic_time(), erlang:unique_integer([positive])}),
    Hex = binary:encode_hex(crypto:hash(sha256, Seed), lowercase),
    binary:part(Hex, 0, 8).

%% Convert a binary string to a list of byte values.
%% Used by the AST extractor to slice source text by byte offsets.
string_to_bytes(Bin) when is_binary(Bin) ->
    binary_to_list(Bin).

%% Convert a list of byte values back to a binary string.
bytes_to_string(Bytes) when is_list(Bytes) ->
    list_to_binary(Bytes).

%% Check whether any app/client source is newer than the built manifest.
%% Missing manifests or unreadable source paths are treated as stale so the
%% Gleam build path can fail loudly or regenerate the bundle.
is_any_source_newer_than_manifest(Paths) ->
    ManifestPath = <<"priv/static/beacon_client.manifest">>,
    PathsWithClient = case find_client_source() of
        {ok, Src} -> Paths ++ [list_to_binary(Src)];
        none -> Paths
    end,
    is_any_source_newer_than(ManifestPath, PathsWithClient).

is_any_source_newer_than(ManifestBin, Paths) ->
    ManifestPath = to_path(ManifestBin),
    case file:read_file_info(ManifestPath) of
        {error, _} ->
            true;
        {ok, ManifestInfo} ->
            ManifestMtime = element(6, ManifestInfo),
            SourceFiles = lists:flatmap(fun collect_source_files/1, Paths),
            case SourceFiles of
                [] -> true;
                _ ->
                    lists:any(
                        fun(SourcePath) ->
                            source_is_newer(SourcePath, ManifestMtime)
                        end,
                        SourceFiles
                    )
            end
    end.

source_is_newer(SourcePath, ManifestMtime) ->
    case file:read_file_info(SourcePath) of
        {ok, SourceInfo} ->
            element(6, SourceInfo) > ManifestMtime;
        {error, _} ->
            true
    end.

collect_source_files(Path0) ->
    Path = to_path(Path0),
    case filelib:is_dir(Path) of
        true -> collect_source_files_in_dir(Path);
        false ->
            case filelib:is_file(Path) of
                true -> [Path];
                false -> [Path]
            end
    end.

collect_source_files_in_dir(Dir) ->
    case file:list_dir(Dir) of
        {ok, Entries} ->
            lists:flatmap(
                fun(Entry) ->
                    Path = filename:join(Dir, Entry),
                    case filelib:is_dir(Path) of
                        true -> collect_source_files_in_dir(Path);
                        false ->
                            case is_source_extension(filename:extension(Entry)) of
                                true -> [Path];
                                false -> []
                            end
                    end
                end,
                Entries
            );
        {error, _} ->
            [Dir]
    end.

is_source_extension(".gleam") -> true;
is_source_extension(".mjs") -> true;
is_source_extension(".js") -> true;
is_source_extension(".toml") -> true;
is_source_extension(_) -> false.

to_path(Bin) when is_binary(Bin) -> binary_to_list(Bin);
to_path(List) when is_list(List) -> List.

find_client_source() ->
    %% Try multiple locations where beacon_client_ffi.mjs might be
    Candidates = [
        "beacon_client/src/beacon_client_ffi.mjs",
        "../beacon_client/src/beacon_client_ffi.mjs",
        "../../beacon_client/src/beacon_client_ffi.mjs",
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
