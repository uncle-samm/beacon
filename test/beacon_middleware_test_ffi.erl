-module(beacon_middleware_test_ffi).
-export([make_request/2, make_request_with_header/4]).

%% Create a minimal HTTP request for testing middleware.
%% Matches gleam_http's Request type:
%% Request(method, headers, body, scheme, host, port, path, query)
%% Body is `connection` atom — matches beacon/transport/server.Connection type.
make_request(MethodBin, Path) ->
    Method = parse_method(MethodBin),
    {request, Method, [], connection, http, <<"localhost">>, {some, 80}, Path, none}.

make_request_with_header(MethodBin, Path, HeaderName, HeaderValue) ->
    Method = parse_method(MethodBin),
    Headers = [{HeaderName, HeaderValue}],
    {request, Method, Headers, connection, http, <<"localhost">>, {some, 80}, Path, none}.

parse_method(MethodBin) ->
    case MethodBin of
        <<"GET">> -> get;
        <<"POST">> -> post;
        <<"PUT">> -> put;
        <<"DELETE">> -> delete;
        <<"OPTIONS">> -> options;
        _ -> {other, MethodBin}
    end.
