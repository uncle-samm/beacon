-module(beacon_cookie_ffi).
-export([sanitize_cookie_value/1]).

%% Strip CR, LF, and null bytes from cookie values to prevent header injection.
%% Uses binary:replace for reliable byte-level matching.
sanitize_cookie_value(Value) ->
    V1 = binary:replace(Value, <<"\r">>, <<>>, [global]),
    V2 = binary:replace(V1, <<"\n">>, <<>>, [global]),
    binary:replace(V2, <<0>>, <<>>, [global]).
