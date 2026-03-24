-module(beacon_api_test_ffi).
-export([http_get/2]).

%% Simple HTTP GET client for testing API routes.
%% Returns {ok, {simple_response, Status, Body}} or {error, Reason}.
http_get(Port, Path) ->
    case gen_tcp:connect({127,0,0,1}, Port, [binary, {active, false}, {packet, raw}], 5000) of
        {ok, Socket} ->
            Request = iolist_to_binary([
                <<"GET ">>, Path, <<" HTTP/1.1\r\n">>,
                <<"Host: localhost:">>, integer_to_binary(Port), <<"\r\n">>,
                <<"Connection: close\r\n">>,
                <<"\r\n">>
            ]),
            case gen_tcp:send(Socket, Request) of
                ok ->
                    case recv_all(Socket, <<>>) of
                        {ok, Data} ->
                            gen_tcp:close(Socket),
                            parse_http_response(Data);
                        {error, Reason} ->
                            gen_tcp:close(Socket),
                            {error, iolist_to_binary(io_lib:format("recv failed: ~p", [Reason]))}
                    end;
                {error, Reason} ->
                    gen_tcp:close(Socket),
                    {error, iolist_to_binary(io_lib:format("send failed: ~p", [Reason]))}
            end;
        {error, Reason} ->
            {error, iolist_to_binary(io_lib:format("connect failed: ~p", [Reason]))}
    end.

recv_all(Socket, Acc) ->
    case gen_tcp:recv(Socket, 0, 5000) of
        {ok, Data} ->
            recv_all(Socket, <<Acc/binary, Data/binary>>);
        {error, closed} ->
            {ok, Acc};
        {error, Reason} ->
            {error, Reason}
    end.

parse_http_response(Data) ->
    case binary:split(Data, <<"\r\n\r\n">>) of
        [Headers, Body] ->
            Status = parse_status(Headers),
            {ok, {simple_response, Status, Body}};
        _ ->
            {error, <<"malformed HTTP response">>}
    end.

parse_status(Headers) ->
    case binary:split(Headers, <<"\r\n">>) of
        [StatusLine | _] ->
            case binary:split(StatusLine, <<" ">>, [global]) of
                [_, StatusCode | _] ->
                    binary_to_integer(StatusCode);
                _ -> 0
            end;
        _ -> 0
    end.
