-module(beacon_subscription_ffi).
-export([receive_with_commands/2]).

%% Receive either a command from a Gleam Subject or a tagged PubSub notification.
%%
%% Returns:
%%   {command, Msg}           — a ListenerCommand sent via the Subject
%%   {notification, Topic}    — a PubSub broadcast with topic identification
%%   {timeout, nil}           — no message within the timeout period
%%
%% The SubjectTag is the internal reference Gleam uses for Subject(ListenerCommand).
%% PubSub broadcasts arrive as {beacon_pubsub, Topic, _Message}.
receive_with_commands(SubjectTag, Timeout) ->
    receive
        {SubjectTag, Msg} ->
            {command, Msg};
        {beacon_pubsub, Topic, _Msg} ->
            {notification, Topic};
        _Other ->
            %% Ignore unexpected messages (e.g., old-format broadcasts)
            {timeout, nil}
    after
        Timeout ->
            {timeout, nil}
    end.
