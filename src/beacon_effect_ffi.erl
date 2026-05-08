-module(beacon_effect_ffi).
-export([
    get_timer_count/0,
    increment_timer_count/0,
    log_timer_limit_warning/1,
    unique_integer/0,
    register_key_generation/1,
    cancel_key_generation/1,
    is_current_key_generation/2
]).

get_timer_count() ->
    case erlang:get(beacon_timer_count) of
        undefined -> 0;
        N -> N
    end.

increment_timer_count() ->
    Current = get_timer_count(),
    erlang:put(beacon_timer_count, Current + 1),
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
