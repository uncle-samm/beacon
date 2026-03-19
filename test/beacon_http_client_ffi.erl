-module(beacon_http_client_ffi).
-export([start_httpc/0, http_get/1, ws_connect/2, ws_send/2, ws_recv/2, ws_close/1]).

%% Start the inets application (required for httpc).
start_httpc() ->
    inets:start(),
    ssl:start(),
    nil.

%% Make a real HTTP GET request. Returns {ok, {Status, Headers, Body}} or {error, Reason}.
http_get(Url) ->
    UrlStr = binary_to_list(Url),
    case httpc:request(get, {UrlStr, []}, [{timeout, 5000}], [{body_format, binary}]) of
        {ok, {{_, Status, _}, Headers, Body}} ->
            HeadersBin = [{list_to_binary(K), list_to_binary(V)} || {K, V} <- Headers],
            {ok, {Status, HeadersBin, Body}};
        {error, Reason} ->
            {error, list_to_binary(io_lib:format("~p", [Reason]))}
    end.

%% Open a real WebSocket connection via gen_tcp + HTTP upgrade handshake.
ws_connect(Host, Port) ->
    ws_connect(Host, Port, 1).

ws_connect(Host, Port, Attempt) ->
    HostStr = binary_to_list(Host),
    case gen_tcp:connect(HostStr, Port, [binary, {active, false}, {packet, raw}], 5000) of
        {ok, Socket} ->
            %% Send WebSocket upgrade request
            Key = base64:encode(crypto:strong_rand_bytes(16)),
            Req = iolist_to_binary([
                <<"GET /ws HTTP/1.1\r\n">>,
                <<"Host: ">>, Host, <<"\r\n">>,
                <<"Upgrade: websocket\r\n">>,
                <<"Connection: Upgrade\r\n">>,
                <<"Sec-WebSocket-Key: ">>, Key, <<"\r\n">>,
                <<"Sec-WebSocket-Version: 13\r\n">>,
                <<"\r\n">>
            ]),
            ok = gen_tcp:send(Socket, Req),
            %% Read response (101 Switching Protocols)
            case gen_tcp:recv(Socket, 0, 5000) of
                {ok, Response} ->
                    case binary:match(Response, <<"101">>) of
                        {_, _} -> {ok, Socket};
                        nomatch ->
                            gen_tcp:close(Socket),
                            maybe_retry(Host, Port, Attempt, <<"upgrade_failed">>)
                    end;
                {error, Reason} ->
                    gen_tcp:close(Socket),
                    maybe_retry(Host, Port, Attempt, list_to_binary(io_lib:format("recv: ~p", [Reason])))
            end;
        {error, Reason} ->
            maybe_retry(Host, Port, Attempt, list_to_binary(io_lib:format("connect: ~p", [Reason])))
    end.

%% Retry once after a short delay — mirrors real client reconnect behavior.
maybe_retry(_Host, _Port, Attempt, Reason) when Attempt >= 2 ->
    {error, Reason};
maybe_retry(Host, Port, Attempt, _Reason) ->
    timer:sleep(100),
    ws_connect(Host, Port, Attempt + 1).

%% Send a WebSocket text frame. Returns {ok, nil} or {error, Reason}.
ws_send(Socket, Payload) ->
    PayloadBin = if is_binary(Payload) -> Payload; true -> list_to_binary(Payload) end,
    Len = byte_size(PayloadBin),
    %% Client frames MUST be masked (RFC 6455)
    MaskKey = crypto:strong_rand_bytes(4),
    <<M1, M2, M3, M4>> = MaskKey,
    MaskedPayload = mask_payload(PayloadBin, M1, M2, M3, M4, 0, <<>>),
    Frame = if
        Len < 126 ->
            <<1:1, 0:3, 1:4, 1:1, Len:7, MaskKey/binary, MaskedPayload/binary>>;
        Len < 65536 ->
            <<1:1, 0:3, 1:4, 1:1, 126:7, Len:16, MaskKey/binary, MaskedPayload/binary>>;
        true ->
            <<1:1, 0:3, 1:4, 1:1, 127:7, Len:64, MaskKey/binary, MaskedPayload/binary>>
    end,
    case gen_tcp:send(Socket, Frame) of
        ok -> {ok, nil};
        {error, Reason} -> {error, list_to_binary(io_lib:format("~p", [Reason]))}
    end.

%% Receive a WebSocket text frame (simplified — assumes unfragmented, unmasked server frame).
ws_recv(Socket, Timeout) ->
    case gen_tcp:recv(Socket, 0, Timeout) of
        {ok, Data} ->
            case Data of
                <<_Fin:1, _Rsv:3, _Opcode:4, 0:1, Len:7, Rest/binary>> when Len < 126 ->
                    <<Payload:Len/binary, _/binary>> = Rest,
                    {ok, Payload};
                <<_Fin:1, _Rsv:3, _Opcode:4, 0:1, 126:7, Len:16, Rest/binary>> ->
                    <<Payload:Len/binary, _/binary>> = Rest,
                    {ok, Payload};
                _ ->
                    {ok, Data}
            end;
        {error, Reason} ->
            {error, list_to_binary(io_lib:format("~p", [Reason]))}
    end.

%% Close a WebSocket connection.
ws_close(Socket) ->
    gen_tcp:close(Socket),
    nil.

%% XOR mask payload bytes with the 4-byte mask key.
mask_payload(<<>>, _, _, _, _, _, Acc) -> Acc;
mask_payload(<<B, Rest/binary>>, M1, M2, M3, M4, N, Acc) ->
    Mask = case N rem 4 of
        0 -> M1;
        1 -> M2;
        2 -> M3;
        3 -> M4
    end,
    mask_payload(Rest, M1, M2, M3, M4, N + 1, <<Acc/binary, (B bxor Mask)>>).
