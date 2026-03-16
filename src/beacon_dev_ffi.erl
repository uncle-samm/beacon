-module(beacon_dev_ffi).
-export([run_command/1, sleep/1, check_for_changes/1, get_file_timestamps/1,
         do_hot_swap/0, string_contains/2, int_to_string/1, find_gleam_files/1]).

%% Persistent state for file modification tracking
-define(TIMESTAMP_KEY, beacon_dev_timestamps).

run_command(Cmd) ->
    Result = os:cmd(binary_to_list(Cmd)),
    unicode:characters_to_binary(Result).

sleep(Ms) ->
    timer:sleep(Ms),
    nil.

%% Get modification times for all .gleam files in directories.
get_file_timestamps(Dirs) ->
    Files = lists:flatmap(fun(Dir) -> find_gleam_files(Dir) end, Dirs),
    Timestamps = [{F, get_mtime(F)} || F <- Files],
    %% Store for later comparison
    erlang:put(?TIMESTAMP_KEY, Timestamps),
    Timestamps.

%% Check if any files changed since last check.
check_for_changes(Dirs) ->
    OldTimestamps = case erlang:get(?TIMESTAMP_KEY) of
        undefined -> [];
        T -> T
    end,
    Files = lists:flatmap(fun(Dir) -> find_gleam_files(Dir) end, Dirs),
    NewTimestamps = [{F, get_mtime(F)} || F <- Files],
    %% Update stored timestamps
    erlang:put(?TIMESTAMP_KEY, NewTimestamps),
    %% Compare
    OldTimestamps =/= NewTimestamps.

%% Hot-swap all beacon modules that have been recompiled.
do_hot_swap() ->
    BeamDir = "build/dev/erlang/beacon/ebin",
    case file:list_dir(BeamDir) of
        {ok, Files} ->
            BeamFiles = [F || F <- Files, filename:extension(F) =:= ".beam"],
            Count = lists:foldl(
                fun(BeamFile, Acc) ->
                    ModName = list_to_atom(filename:rootname(BeamFile)),
                    case code:load_file(ModName) of
                        {module, _} -> Acc + 1;
                        _ -> Acc
                    end
                end,
                0,
                BeamFiles
            ),
            {ok, Count};
        {error, Reason} ->
            {error, list_to_binary(io_lib:format("~p", [Reason]))}
    end.

%% Find all .gleam files recursively in a directory.
find_gleam_files(Dir) ->
    DirStr = binary_to_list(Dir),
    case filelib:is_dir(DirStr) of
        true ->
            {ok, Entries} = file:list_dir(DirStr),
            lists:flatmap(
                fun(Entry) ->
                    Path = filename:join(DirStr, Entry),
                    case filelib:is_dir(Path) of
                        true ->
                            find_gleam_files(list_to_binary(Path));
                        false ->
                            case filename:extension(Entry) of
                                ".gleam" -> [list_to_binary(Path)];
                                _ -> []
                            end
                    end
                end,
                Entries
            );
        false ->
            []
    end.

%% Get file modification time as epoch seconds.
get_mtime(File) ->
    case file:read_file_info(binary_to_list(File)) of
        {ok, Info} ->
            calendar:datetime_to_gregorian_seconds(element(6, Info));
        _ ->
            0
    end.

string_contains(Haystack, Needle) ->
    case binary:match(Haystack, Needle) of
        nomatch -> false;
        _ -> true
    end.

int_to_string(N) ->
    integer_to_binary(N).
