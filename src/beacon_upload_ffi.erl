-module(beacon_upload_ffi).
-export([write_file/2, binary_split/2, binary_split_once/2, trim_trailing_crlf/1]).

write_file(Path, Data) ->
    case validate_path(Path) of
        ok ->
            case file:write_file(Path, Data) of
                ok -> {ok, nil};
                {error, Reason} ->
                    logger:error("File write failed: path=~s reason=~p", [Path, Reason]),
                    {error, list_to_binary(io_lib:format("write failed: ~p", [Reason]))}
            end;
        {error, Msg} ->
            logger:error("Path traversal attempt blocked: path=~s reason=~s", [Path, Msg]),
            {error, list_to_binary(Msg)}
    end.

validate_path(Path) when is_binary(Path) ->
    validate_path(binary_to_list(Path));
validate_path(Path) when is_list(Path) ->
    %% Split path into components and check each one for ".."
    Components = filename:split(Path),
    case lists:member("..", Components) of
        true ->
            {error, "path traversal (..) is not allowed"};
        false ->
            ok
    end.

%% Split binary data on a separator, returning list of parts.
binary_split(Data, Separator) ->
    binary:split(Data, Separator, [global]).

%% Split binary data on separator, returning first occurrence as {Before, After}.
binary_split_once(Data, Separator) ->
    case binary:split(Data, Separator) of
        [Before, After] -> {ok, {Before, After}};
        _ -> {error, nil}
    end.

%% Trim trailing \r\n from binary data.
trim_trailing_crlf(Data) ->
    Size = byte_size(Data),
    case Size >= 2 of
        true ->
            case binary:part(Data, Size - 2, 2) of
                <<"\r\n">> -> binary:part(Data, 0, Size - 2);
                _ -> Data
            end;
        false -> Data
    end.
