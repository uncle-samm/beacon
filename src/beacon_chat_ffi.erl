-module(beacon_chat_ffi).
-export([new_store/1, append_message/3, get_messages/2]).

%% Create a new ETS table for storing chat messages.
%% Uses a bag (allows multiple entries per key = room name).
new_store(Name) ->
    AtomName = binary_to_atom(<<"beacon_chat_", Name/binary>>, utf8),
    ets:new(AtomName, [bag, public, named_table, {read_concurrency, true}]).

%% Append a message to a room.
append_message(Store, Room, Msg) ->
    ets:insert(Store, {Room, Msg}),
    nil.

%% Get all messages for a room, in insertion order.
get_messages(Store, Room) ->
    case ets:lookup(Store, Room) of
        [] -> [];
        Entries -> [Msg || {_, Msg} <- Entries]
    end.
