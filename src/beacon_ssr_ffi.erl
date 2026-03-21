-module(beacon_ssr_ffi).
-export([system_time_seconds/0, priv_dir/0]).

system_time_seconds() ->
    erlang:system_time(second).

%% Resolve Beacon's priv directory using code:priv_dir/1.
%% This works whether Beacon is the top-level app or a dependency.
priv_dir() ->
    case code:priv_dir(beacon) of
        {error, _} ->
            %% Fallback: check if priv/ exists relative to CWD
            %% (development mode, running from the beacon repo itself)
            case filelib:is_dir("priv") of
                true -> {ok, <<"priv">>};
                false -> {error, <<"beacon priv dir not found">>}
            end;
        Dir when is_list(Dir) ->
            {ok, list_to_binary(Dir)}
    end.
