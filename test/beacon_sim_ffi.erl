-module(beacon_sim_ffi).
-export([
    new_metrics/0, increment/2, increment_by/3, record_latency/2, collect/1, destroy/1,
    monotonic_us/0, snapshot_memory/0, snapshot_processes/0,
    message_queue_len/1
]).

%% Create a new metrics ETS table. Returns table reference.
%% Uses two tables: one set for counters, one bag for latency samples.
new_metrics() ->
    Counters = ets:new(sim_counters, [set, public, {write_concurrency, true}]),
    Latencies = ets:new(sim_latencies, [bag, public, {write_concurrency, true}]),
    %% Initialize all counters to 0
    ets:insert(Counters, {events_sent, 0}),
    ets:insert(Counters, {events_acked, 0}),
    ets:insert(Counters, {events_failed, 0}),
    ets:insert(Counters, {connections_opened, 0}),
    ets:insert(Counters, {connections_closed, 0}),
    ets:insert(Counters, {connections_failed, 0}),
    ets:insert(Counters, {bytes_sent, 0}),
    ets:insert(Counters, {bytes_received, 0}),
    ets:insert(Counters, {patches_received, 0}),
    ets:insert(Counters, {model_syncs_received, 0}),
    ets:insert(Counters, {mounts_received, 0}),
    {Counters, Latencies}.

%% Atomically increment a counter by 1.
increment({Counters, _Latencies}, Key) ->
    case validate_atom_name(Key) of
        ok ->
            AtomKey = binary_to_atom(Key, utf8),
            try
                ets:update_counter(Counters, AtomKey, 1),
                nil
            catch
                error:badarg ->
                    %% Counter didn't exist, create it
                    ets:insert(Counters, {AtomKey, 1}),
                    nil
            end;
        {error, Reason} ->
            error(Reason)
    end.

%% Atomically increment a counter by N.
increment_by({Counters, _Latencies}, Key, Amount) ->
    case validate_atom_name(Key) of
        ok ->
            AtomKey = binary_to_atom(Key, utf8),
            try
                ets:update_counter(Counters, AtomKey, Amount),
                nil
            catch
                error:badarg ->
                    ets:insert(Counters, {AtomKey, Amount}),
                    nil
            end;
        {error, Reason} ->
            error(Reason)
    end.

%% Validate that a name is safe for atom conversion.
%% Max 255 bytes, alphanumeric + underscore + hyphen only (no spaces, no special chars).
%% This prevents atom table exhaustion from arbitrary user-controlled input.
validate_atom_name(Name) when byte_size(Name) > 255 ->
    {error, <<"Name too long (max 255 bytes)">>};
validate_atom_name(Name) ->
    case re:run(Name, <<"^[a-zA-Z0-9_-]+$">>) of
        {match, _} -> ok;
        nomatch -> {error, <<"Invalid name: must be alphanumeric, underscore, or hyphen">>}
    end.

%% Record a latency sample (microseconds).
record_latency({_Counters, Latencies}, LatencyUs) ->
    ets:insert(Latencies, {latency, LatencyUs}),
    nil.

%% Collect all metrics into a Gleam-friendly structure.
%% Returns: {EventsSent, EventsAcked, EventsFailed,
%%           ConnOpened, ConnClosed, ConnFailed, Latencies}
collect({Counters, Latencies}) ->
    Get = fun(Key) ->
        case ets:lookup(Counters, Key) of
            [{_, Val}] -> Val;
            [] -> 0
        end
    end,
    LatencyList = [L || {latency, L} <- ets:tab2list(Latencies)],
    {
        Get(events_sent),
        Get(events_acked),
        Get(events_failed),
        Get(connections_opened),
        Get(connections_closed),
        Get(connections_failed),
        LatencyList,
        Get(bytes_sent),
        Get(bytes_received),
        Get(patches_received),
        Get(model_syncs_received),
        Get(mounts_received)
    }.

%% Delete metrics tables.
destroy({Counters, Latencies}) ->
    ets:delete(Counters),
    ets:delete(Latencies),
    nil.

%% Get monotonic time in microseconds (for latency measurement).
monotonic_us() ->
    erlang:monotonic_time(microsecond).

%% Get total BEAM memory in bytes.
snapshot_memory() ->
    erlang:memory(total).

%% Get total process count.
snapshot_processes() ->
    erlang:system_info(process_count).

%% Get message queue length for a process.
message_queue_len(Pid) ->
    case erlang:process_info(Pid, message_queue_len) of
        {message_queue_len, Len} -> Len;
        undefined -> -1
    end.
