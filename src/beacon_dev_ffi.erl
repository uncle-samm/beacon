-module(beacon_dev_ffi).
-export([run_program/3, sleep/1, check_for_changes/1, get_file_timestamps/1,
         do_hot_swap/0, int_to_string/1, find_gleam_files/1,
         start_native_watcher/1, poll_native_watcher/0, native_watcher_available/0,
         notify_browser_reload/0]).

%% Persistent state for file modification tracking
-define(TIMESTAMP_KEY, beacon_dev_timestamps).

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
                        {error, Reason} ->
                            logger:warning("[beacon.dev] Failed to hot-swap module ~p: ~p", [ModName, Reason]),
                            Acc
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
        {error, Reason} ->
            logger:warning("[beacon.dev] Failed to stat file ~s: ~p", [File, Reason]),
            0
    end.

int_to_string(N) ->
    integer_to_binary(N).

%% Notify connected browsers to reload via PubSub.
notify_browser_reload() ->
    %% Broadcast to the beacon:reload topic — any listening WS connections will pick this up
    try pg:get_members(beacon_pg, <<"beacon:reload">>) of
        Pids ->
            [Pid ! {beacon_reload} || Pid <- Pids],
            {ok, nil}
    catch
        Class:Reason ->
            logger:warning("[beacon.dev] notify_browser_reload failed: ~p:~p", [Class, Reason]),
            {error, iolist_to_binary(io_lib:format("~p:~p", [Class, Reason]))}
    end.

%% Check if a native file watcher (fswatch or inotifywait) is available.
native_watcher_available() ->
    case os:type() of
        {unix, darwin} ->
            case os:find_executable("fswatch") of
                false -> false;
                _ -> true
            end;
        {unix, linux} ->
            case os:find_executable("inotifywait") of
                false -> false;
                _ -> true
            end;
        _ -> false
    end.

%% Start a native file watcher process. Returns a port.
%% On macOS: uses fswatch. On Linux: uses inotifywait.
start_native_watcher(Dirs) ->
    DirArgs = [binary_to_list(D) || D <- Dirs],
    Command = case os:type() of
        {unix, darwin} ->
            {ok, "fswatch", ["-1", "--include", "\\.gleam$", "--exclude", ".*"] ++ DirArgs};
	    {unix, linux} ->
	        {ok, "inotifywait", ["-r", "-e", "modify,create,delete", "--include", "\\.gleam$"] ++ DirArgs};
	    Other ->
	        {unsupported, Other}
	end,
	case Command of
	    {unsupported, OtherOs} ->
	        Reason = unicode:characters_to_binary(
	            io_lib:format("native watcher unsupported for os:type()=~p", [OtherOs])
	        ),
	        {error, Reason};
	    {ok, Program, Args} ->
	        case os:find_executable(Program) of
	            false ->
	                {error, unicode:characters_to_binary(["Executable not found: ", Program])};
	            Executable ->
	                try open_port(
	                        {spawn_executable, Executable},
	                        [{args, Args}, stream, exit_status, binary]
	                    ) of
	                    Port ->
	                        erlang:put(beacon_native_watcher_port, Port),
	                        {ok, nil}
	                catch
	                    error:Reason ->
	                        {error, unicode:characters_to_binary(
	                            io_lib:format("Failed to start watcher ~s: ~p", [Program, Reason])
	                        )}
	                end
	        end
	end.

%% Poll the native watcher — returns true if a change was detected.
%% Non-blocking: checks if the port has sent any data.
poll_native_watcher() ->
    case erlang:get(beacon_native_watcher_port) of
        undefined -> false;
        Port ->
            receive
                {Port, {data, _}} ->
                    %% Change detected! Restart the watcher for next change.
                    true;
                {Port, {exit_status, _}} ->
                    %% Watcher exited (fswatch -1 does this after one event)
                    true
            after 100 ->
                false
            end
    end.
