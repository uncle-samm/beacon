-module(beacon_application_ffi).
-export([trap_exit/0, receive_shutdown_signal/1, get_env_int/1]).

%% Enable trapping of exit signals (SIGTERM etc.)
trap_exit() ->
    process_flag(trap_exit, true),
    nil.

%% Wait for a shutdown signal (EXIT message from supervisor/system).
%% Returns true if shutdown received, false on timeout.
receive_shutdown_signal(Timeout) ->
    receive
        {'EXIT', _From, shutdown} -> true;
        {'EXIT', _From, {shutdown, _}} -> true;
        {'EXIT', _From, normal} -> true
    after Timeout ->
        false
    end.

%% Get an integer environment variable.
get_env_int(Name) ->
    case os:getenv(binary_to_list(Name)) of
        false -> {error, nil};
        Value ->
            case catch list_to_integer(Value) of
                N when is_integer(N) -> {ok, N};
                _ -> {error, nil}
            end
    end.
