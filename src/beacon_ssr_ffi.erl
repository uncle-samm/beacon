-module(beacon_ssr_ffi).
-export([system_time_seconds/0, priv_dir/0]).

system_time_seconds() ->
    erlang:system_time(second).

%% Resolve Beacon's priv directory using code:priv_dir/1.
%% This works whether Beacon is the top-level app or a dependency.
priv_dir() ->
    case code:priv_dir(beacon) of
        {error, Reason} ->
            ReasonBin = unicode:characters_to_binary(io_lib:format("~p", [Reason])),
            {error, <<"beacon priv dir not found via code:priv_dir/1: ", ReasonBin/binary>>};
        Dir when is_list(Dir) ->
            {ok, list_to_binary(Dir)}
    end.
