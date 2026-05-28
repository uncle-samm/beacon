-module(beacon_effect_ffi).
-export([
    live_timer_count/0,
    register_timer/1,
    log_timer_limit_warning/1,
    unique_integer/0,
    register_key_generation/1,
    cancel_key_generation/1,
    is_current_key_generation/2
]).

%% Count timers that are still alive, pruning any dead pids from the
%% tracked list. Self-healing: a timer that exited (e.g. its session
%% process died) no longer counts against the limit. This runs inside
%% the runtime process, so the list lives in that process dictionary.
live_timer_count() ->
    Pids =
        case erlang:get(beacon_timer_pids) of
            undefined -> [];
            L when is_list(L) -> L
        end,
    Alive = [P || P <- Pids, is_process_alive(P)],
    erlang:put(beacon_timer_pids, Alive),
    length(Alive).

%% Track a newly spawned timer pid so it counts toward the live limit.
register_timer(Pid) ->
    Pids =
        case erlang:get(beacon_timer_pids) of
            undefined -> [];
            L when is_list(L) -> L
        end,
    erlang:put(beacon_timer_pids, [Pid | Pids]),
    nil.

log_timer_limit_warning(Current) ->
    logger:warning("[beacon.effect] Timer limit reached (~p/~p) - new timer rejected", [Current, 10]),
    nil.

unique_integer() ->
    erlang:unique_integer([monotonic, positive]).

register_key_generation(Key) ->
    Generations =
        case erlang:get(beacon_effect_generations) of
            undefined -> #{};
            Map -> Map
        end,
    Generation = maps:get(Key, Generations, 0) + 1,
    erlang:put(beacon_effect_generations, maps:put(Key, Generation, Generations)),
    Generation.

cancel_key_generation(Key) ->
    _ = register_key_generation(Key),
    nil.

is_current_key_generation(Key, Generation) ->
    Generations =
        case erlang:get(beacon_effect_generations) of
            undefined -> #{};
            Map -> Map
        end,
    maps:get(Key, Generations, 0) =:= Generation.
