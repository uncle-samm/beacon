-module(beacon_auth_ffi).
-export([find_cookie/2]).

%% Extract a cookie value from a cookie header string.
%% Target format: "name="
find_cookie(Header, Target) ->
    case binary:match(Header, Target) of
        {Start, Len} ->
            ValueStart = Start + Len,
            Rest = binary:part(Header, ValueStart, byte_size(Header) - ValueStart),
            Value = case binary:match(Rest, <<";">>) of
                {SemiPos, _} -> binary:part(Rest, 0, SemiPos);
                nomatch -> Rest
            end,
            %% Trim whitespace
            Trimmed = string:trim(Value),
            {ok, Trimmed};
        nomatch ->
            {error, nil}
    end.
