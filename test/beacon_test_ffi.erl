-module(beacon_test_ffi).
-export([unique_ref/0, pd_put/2, pd_get/1, string_contains/2, do_crash/0]).

%% Returns a unique binary string.
unique_ref() ->
    erlang:integer_to_binary(erlang:unique_integer([positive])).

%% Put a value in the process dictionary.
pd_put(Key, Value) ->
    erlang:put(Key, Value),
    nil.

%% Get a value from the process dictionary.
pd_get(Key) ->
    erlang:get(Key).

%% Check if a binary string contains a substring.
string_contains(Haystack, Needle) ->
    case binary:match(Haystack, Needle) of
        nomatch -> false;
        _ -> true
    end.

%% Intentionally crash for testing error boundaries.
do_crash() ->
    error(intentional_test_crash).
