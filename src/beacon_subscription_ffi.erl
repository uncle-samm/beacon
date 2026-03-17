-module(beacon_subscription_ffi).
-export([receive_with_commands/2]).

%% Receive either a command from a Gleam Subject or a tagged PubSub notification.
%%
%% Subject is a Gleam record: {subject, Pid, Tag}
%% Messages sent via process.send(subject, msg) arrive as {Tag, Msg}.
%% PubSub broadcasts arrive as {beacon_pubsub, Topic, _Message}.
%%
%% Returns Gleam-compatible tuples matching ListenerReceiveResult variants:
%%   {command_received, Msg}       — CommandReceived
%%   {notification_received, Topic} — NotificationReceived
%%   receive_timeout                — ReceiveTimeout
receive_with_commands(Subject, Timeout) ->
    {subject, _Pid, Tag} = Subject,
    receive
        {Tag, Msg} ->
            {command_received, Msg};
        {beacon_pubsub, Topic, _Msg} ->
            {notification_received, Topic};
        _Other ->
            receive_with_commands(Subject, Timeout)
    after
        Timeout ->
            receive_timeout
    end.
