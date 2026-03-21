-module(beacon_transport_ffi).
-export([
    listen/2, accept/1, tcp_send/2, close/1,
    controlling_process/2, set_active_once/1,
    read_http_request/1, read_body/2,
    ws_accept_key/1,
    ws_encode_text_frame/1, ws_encode_close_frame/0,
    ws_decode_frame/1,
    classify_tcp_message/1,
    start_acceptor_pool/3
]).

%% --- TCP Operations ---

listen(Port, Backlog) ->
    case gen_tcp:listen(Port, [
        binary,
        {active, false},
        {reuseaddr, true},
        {backlog, Backlog},
        {nodelay, true}
    ]) of
        {ok, Socket} -> {ok, Socket};
        {error, Reason} -> {error, format_reason(Reason)}
    end.

accept(ListenSocket) ->
    case gen_tcp:accept(ListenSocket) of
        {ok, Socket} -> {ok, Socket};
        {error, Reason} -> {error, format_reason(Reason)}
    end.

tcp_send(Socket, Data) ->
    case gen_tcp:send(Socket, Data) of
        ok -> {ok, nil};
        {error, Reason} -> {error, format_reason(Reason)}
    end.

close(Socket) ->
    gen_tcp:close(Socket),
    nil.

controlling_process(Socket, Pid) ->
    case gen_tcp:controlling_process(Socket, Pid) of
        ok -> {ok, nil};
        {error, Reason} -> {error, format_reason(Reason)}
    end.

set_active_once(Socket) ->
    inet:setopts(Socket, [{active, once}]),
    nil.

%% --- HTTP Request Parsing ---
%% Uses Erlang's {packet, http_bin} mode for efficient parsing.
%% Returns: {ok, {MethodBin, PathBin, [{KeyBin, ValueBin}]}} | {error, Reason}

read_http_request(Socket) ->
    case inet:setopts(Socket, [{packet, http_bin}]) of
        {error, Reason} ->
            {error, format_reason(Reason)};
        ok ->
            case gen_tcp:recv(Socket, 0, 30000) of
                {ok, {http_request, Method, {abs_path, Path}, _Version}} ->
                    case read_headers(Socket, []) of
                        {ok, Headers} ->
                            inet:setopts(Socket, [{packet, raw}]),
                            {ok, {method_to_binary(Method), Path, Headers}};
                        {error, Reason2} ->
                            inet:setopts(Socket, [{packet, raw}]),
                            {error, Reason2}
                    end;
                {ok, {http_error, _}} ->
                    inet:setopts(Socket, [{packet, raw}]),
                    {error, <<"bad_request">>};
                {error, closed} ->
                    {error, <<"closed">>};
                {error, Reason3} ->
                    inet:setopts(Socket, [{packet, raw}]),
                    {error, format_reason(Reason3)}
            end
    end.

read_headers(Socket, Acc) ->
    case gen_tcp:recv(Socket, 0, 30000) of
        {ok, {http_header, _, Name, _, Value}} ->
            Key = normalize_header_name(Name),
            read_headers(Socket, [{Key, Value} | Acc]);
        {ok, http_eoh} ->
            {ok, lists:reverse(Acc)};
        {ok, {http_error, _}} ->
            {error, <<"bad_header">>};
        {error, Reason} ->
            {error, format_reason(Reason)}
    end.

%% Read exactly Length bytes from the socket (request body).
%% Socket must be in {packet, raw} mode (set by read_http_request after headers).
%% MaxBytes is the safety limit — if Length > MaxBytes, returns error without reading.
%% Returns {ok, Data} or {error, Reason}.
read_body(Socket, Length) ->
    case gen_tcp:recv(Socket, Length, 30000) of
        {ok, Data} ->
            {ok, Data};
        {error, closed} ->
            {error, <<"closed">>};
        {error, Reason} ->
            {error, format_reason(Reason)}
    end.

normalize_header_name(Name) when is_atom(Name) ->
    string:lowercase(atom_to_binary(Name, utf8));
normalize_header_name(Name) when is_binary(Name) ->
    string:lowercase(Name).

method_to_binary('GET') -> <<"GET">>;
method_to_binary('POST') -> <<"POST">>;
method_to_binary('PUT') -> <<"PUT">>;
method_to_binary('DELETE') -> <<"DELETE">>;
method_to_binary('HEAD') -> <<"HEAD">>;
method_to_binary('OPTIONS') -> <<"OPTIONS">>;
method_to_binary('PATCH') -> <<"PATCH">>;
method_to_binary(Other) when is_atom(Other) -> atom_to_binary(Other, utf8);
method_to_binary(Other) -> Other.

%% --- WebSocket ---

%% Compute Sec-WebSocket-Accept key per RFC 6455.
ws_accept_key(ClientKey) ->
    Guid = <<"258EAFA5-E914-47DA-95CA-C5AB0DC85B11">>,
    Hash = crypto:hash(sha, <<ClientKey/binary, Guid/binary>>),
    base64:encode(Hash).

%% Encode a text frame (server → client, unmasked).
ws_encode_text_frame(Text) when is_binary(Text) ->
    Len = byte_size(Text),
    if
        Len < 126 ->
            <<1:1, 0:3, 1:4, 0:1, Len:7, Text/binary>>;
        Len < 65536 ->
            <<1:1, 0:3, 1:4, 0:1, 126:7, Len:16, Text/binary>>;
        true ->
            <<1:1, 0:3, 1:4, 0:1, 127:7, Len:64, Text/binary>>
    end.

%% Encode a close frame (server → client, unmasked, no status).
ws_encode_close_frame() ->
    <<1:1, 0:3, 8:4, 0:1, 0:7>>.

%% Decode a WebSocket frame from raw bytes.
%% Client frames are always masked (RFC 6455 Section 5.1).
%% Returns: {ok, {Opcode, UnmaskedPayload, RemainingData}} | {error, <<"incomplete">>}
ws_decode_frame(Data) ->
    case Data of
        %% 7-bit length (< 126), masked
        <<_Fin:1, _Rsv:3, Opcode:4, 1:1, Len:7, Mask:4/binary, Rest/binary>>
          when Len < 126, byte_size(Rest) >= Len ->
            <<Payload:Len/binary, Remaining/binary>> = Rest,
            Unmasked = unmask(Payload, Mask),
            {ok, {Opcode, Unmasked, Remaining}};
        %% 16-bit length (126), masked
        <<_Fin:1, _Rsv:3, Opcode:4, 1:1, 126:7, Len:16, Mask:4/binary, Rest/binary>>
          when byte_size(Rest) >= Len ->
            <<Payload:Len/binary, Remaining/binary>> = Rest,
            Unmasked = unmask(Payload, Mask),
            {ok, {Opcode, Unmasked, Remaining}};
        %% 64-bit length (127), masked
        <<_Fin:1, _Rsv:3, Opcode:4, 1:1, 127:7, Len:64, Mask:4/binary, Rest/binary>>
          when byte_size(Rest) >= Len ->
            <<Payload:Len/binary, Remaining/binary>> = Rest,
            Unmasked = unmask(Payload, Mask),
            {ok, {Opcode, Unmasked, Remaining}};
        %% Unmasked frame from client — protocol violation
        <<_Fin:1, _Rsv:3, _Opcode:4, 0:1, _/binary>> when byte_size(Data) >= 2 ->
            {error, <<"protocol_violation_unmasked">>};
        %% Incomplete frame
        _ ->
            {error, <<"incomplete">>}
    end.

%% Unmask payload using XOR with 4-byte mask key.
%% Uses crypto:exor for efficiency.
unmask(Payload, Mask) ->
    Len = byte_size(Payload),
    case Len of
        0 -> <<>>;
        _ ->
            Reps = Len div 4,
            Rem = Len rem 4,
            FullMask = binary:copy(Mask, Reps),
            PartMask = binary:part(Mask, 0, Rem),
            FullKey = <<FullMask/binary, PartMask/binary>>,
            crypto:exor(Payload, FullKey)
    end.

%% --- TCP Message Classification ---
%% Classifies raw Erlang messages received via {active, once} mode.
%% Maps to Gleam TcpMsg type constructors.

classify_tcp_message({tcp, _Socket, Data}) ->
    {ok, {tcp_data, Data}};
classify_tcp_message({tcp_closed, _Socket}) ->
    {ok, tcp_closed};
classify_tcp_message({tcp_error, _Socket, Reason}) ->
    {ok, {tcp_error, format_reason(Reason)}};
classify_tcp_message(_) ->
    {error, nil}.

%% --- Acceptor Loop ---
%% Accept a connection, spawn a replacement acceptor, then handle the
%% connection in THIS process. Eliminates controlling_process entirely —
%% the accepting process already owns the socket, so there is no ownership
%% transfer window. This is the Ranch/Glisten pattern and is immune to
%% thundering-herd races.

%% Start N acceptors and wait for all to be blocked on gen_tcp:accept.
%% Uses a probe connection to verify the accept queue is active:
%% after spawning all acceptors, connects and immediately disconnects.
%% If the connect succeeds, at least one acceptor was ready.
%% We add a small yield to let all acceptors enter their accept calls.
start_acceptor_pool(ListenSocket, HandlerFun, Count) ->
    lists:foreach(fun(_) ->
        spawn(fun() -> acceptor_loop(ListenSocket, HandlerFun) end)
    end, lists:seq(1, Count)),
    %% Probe connection: verify at least one acceptor is blocking on accept.
    %% This eliminates the cold-start race where connections arrive before
    %% acceptors have entered gen_tcp:accept. The probe connects, the handler
    %% sees an empty read (closed), and exits cleanly.
    {ok, {Addr, Port}} = inet:sockname(ListenSocket),
    ConnAddr = case Addr of
        {0,0,0,0} -> {127,0,0,1};
        {0,0,0,0,0,0,0,0} -> {0,0,0,0,0,0,0,1};
        Other -> Other
    end,
    case gen_tcp:connect(ConnAddr, Port, [binary], 1000) of
        {ok, Probe} -> gen_tcp:close(Probe);
        {error, _} -> timer:sleep(10)
    end,
    nil.

acceptor_loop(ListenSocket, HandlerFun) ->
    case gen_tcp:accept(ListenSocket) of
        {ok, Socket} ->
            %% Spawn replacement acceptor BEFORE handling (keeps pool full).
            %% MUST be unlinked — if linked, handler exit kills the replacement.
            spawn(fun() -> acceptor_loop(ListenSocket, HandlerFun) end),
            %% This process becomes the handler (already owns Socket)
            try
                HandlerFun(Socket)
            catch
                _Class:_Reason ->
                    gen_tcp:close(Socket)
            end;
        {error, closed} ->
            %% Listen socket closed — server is shutting down
            ok;
        {error, _Reason} ->
            timer:sleep(100),
            acceptor_loop(ListenSocket, HandlerFun)
    end.

%% --- Helpers ---

format_reason(Reason) when is_atom(Reason) ->
    atom_to_binary(Reason, utf8);
format_reason(Reason) when is_binary(Reason) ->
    Reason;
format_reason(Reason) ->
    list_to_binary(io_lib:format("~p", [Reason])).
