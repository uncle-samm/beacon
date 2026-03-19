-module(beacon_effect_ffi).
-export([get_timer_count/0, increment_timer_count/0, log_timer_limit_warning/1]).

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
