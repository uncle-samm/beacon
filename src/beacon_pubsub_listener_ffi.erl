-module(beacon_pubsub_listener_ffi).
-export([receive_any/1]).

%% Wait for any message with a timeout.
%% Used by the PubSub listener to catch raw Erlang messages sent by pg.
receive_any(Timeout) ->
    receive
        _Any -> nil
    after
        Timeout -> nil
    end.
