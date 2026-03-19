-module(beacon_router_ffi).
-export([call_start_for_route/3, call_ssr_for_route/3, dispatcher_available/0, hot_reload_dispatcher/0, purge_stale_codec/0]).

%% Dynamically call the generated route dispatcher's start_for_route/3.
%% The generated module is 'generated@route_dispatcher' (Gleam uses @ for path separators).
%% Returns the same Result type the generated function returns.
call_start_for_route(ConnId, TransportSubject, Path) ->
    Mod = 'generated@route_dispatcher',
    case code:ensure_loaded(Mod) of
        {module, Mod} ->
            Mod:start_for_route(ConnId, TransportSubject, Path);
        {error, Reason} ->
            {error, {router_error, iolist_to_binary(
                io_lib:format("Route dispatcher not available: ~p. Run `gleam run -m beacon/router/codegen` first.", [Reason])
            )}}
    end.

%% Dynamically call the generated route dispatcher's ssr_for_route/3.
call_ssr_for_route(Path, Title, SecretKey) ->
    Mod = 'generated@route_dispatcher',
    case code:ensure_loaded(Mod) of
        {module, Mod} ->
            {ok, Mod:ssr_for_route(Path, Title, SecretKey)};
        {error, Reason} ->
            logger:error("[beacon.router] SSR dispatcher not available: ~p. Run `gleam run -m beacon/router/codegen` first.", [Reason]),
            {error, {render_error, iolist_to_binary(
                io_lib:format("Route dispatcher not available for SSR: ~p. Run `gleam run -m beacon/router/codegen` first.", [Reason])
            )}}
    end.

%% Check if the route dispatcher module is available.
dispatcher_available() ->
    Mod = 'generated@route_dispatcher',
    case code:ensure_loaded(Mod) of
        {module, Mod} -> true;
        {error, _} -> false
    end.

%% Purge any stale beacon_codec module so runtimes don't auto-discover it.
%% For routed apps, each route has different Model/Msg types, so a global codec is wrong.
purge_stale_codec() ->
    code:purge(beacon_codec),
    code:delete(beacon_codec),
    code:purge(beacon_codec),
    io:format("[beacon] Purged stale beacon_codec~n"),
    nil.

%% Hot-reload the generated route dispatcher module.
hot_reload_dispatcher() ->
    Mod = 'generated@route_dispatcher',
    code:purge(Mod),
    case code:load_file(Mod) of
        {module, Mod} ->
            io:format("[beacon] Route dispatcher hot-reloaded~n"),
            nil;
        {error, Reason} ->
            io:format("[beacon] Warning: Could not reload route dispatcher: ~p~n", [Reason]),
            nil
    end.
