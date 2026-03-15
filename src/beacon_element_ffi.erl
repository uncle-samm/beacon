-module(beacon_element_ffi).
-export([string_replace/3]).

%% Replace all occurrences of Pattern in Subject with Replacement.
string_replace(Subject, Pattern, Replacement) ->
    binary:replace(Subject, Pattern, Replacement, [global]).
