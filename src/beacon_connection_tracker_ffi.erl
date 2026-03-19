-module(beacon_connection_tracker_ffi).
-export([init/0, increment/0, decrement/0, count/0]).

%% Initialize the ETS table for tracking global connection count.
%% Safe to call multiple times — only creates the table on first call.
init() ->
    case ets:info(beacon_conn_tracker) of
        undefined ->
            ets:new(beacon_conn_tracker, [set, public, named_table]),
            ets:insert(beacon_conn_tracker, {count, 0}),
            nil;
        _ ->
            nil
    end.

%% Atomically increment the global connection count. Returns the new value.
increment() ->
    init(),
    ets:update_counter(beacon_conn_tracker, count, 1).

%% Atomically decrement the global connection count. Returns the new value.
%% Clamps to 0 to prevent negative counts from bugs.
decrement() ->
    init(),
    New = ets:update_counter(beacon_conn_tracker, count, {2, -1, 0, 0}),
    New.

%% Read the current connection count.
count() ->
    init(),
    case ets:lookup(beacon_conn_tracker, count) of
        [{count, N}] -> N;
        _ -> 0
    end.
