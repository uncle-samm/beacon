-module(beacon_upload_ffi).
-export([write_file/2]).

write_file(Path, Data) ->
    case file:write_file(Path, Data) of
        ok -> {ok, nil};
        {error, _Reason} -> {error, nil}
    end.
