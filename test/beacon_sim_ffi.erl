-module(beacon_sim_ffi).
-export([
    new_metrics/0, increment/2, record_latency/2, collect/1, destroy/1,
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
    {Counters, Latencies}.

%% Atomically increment a counter by 1.
increment({Counters, _Latencies}, Key) ->
    AtomKey = binary_to_atom(Key, utf8),
    try
        ets:update_counter(Counters, AtomKey, 1),
        nil
    catch
        error:badarg ->
            %% Counter didn't exist, create it
            ets:insert(Counters, {AtomKey, 1}),
            nil
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
        LatencyList
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
