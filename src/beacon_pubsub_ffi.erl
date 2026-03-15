-module(beacon_pubsub_ffi).
-export([pg_start/0, pg_join/2, pg_leave/2, pg_get_members/1, erlang_send/2]).

%% Ensure the default pg scope is started.
pg_start() ->
    case pg:start(beacon_pg) of
        {ok, _Pid} -> nil;
        {error, {already_started, _Pid}} -> nil
    end.

%% Join a process group (topic).
pg_join(Topic, Pid) ->
    pg:join(beacon_pg, Topic, Pid),
    nil.

%% Leave a process group (topic).
pg_leave(Topic, Pid) ->
    pg:leave(beacon_pg, Topic, Pid),
    nil.

%% Get all members of a process group (topic).
pg_get_members(Topic) ->
    pg:get_members(beacon_pg, Topic).

%% Send a message to a process.
erlang_send(Pid, Message) ->
    Pid ! Message,
    nil.
