-module(beacon_auto_build_ffi).
-export([hot_reload_codec/0]).

%% Hot-reload the beacon_codec module after auto-build regenerates it.
%% Uses code:purge + code:load_file to replace the old module in memory.
hot_reload_codec() ->
    code:purge(beacon_codec),
    case code:load_file(beacon_codec) of
        {module, beacon_codec} ->
            logger:info("[beacon] Hot-reloaded beacon_codec module"),
            %% Verify the new function works
            case erlang:function_exported(beacon_codec, encode_model, 1) of
                true ->
                    %% Check module info to verify it's the new version
                    Exports = beacon_codec:module_info(exports),
                    logger:info("[beacon] beacon_codec exports: ~p", [Exports]),
                    nil;
                false ->
                    logger:warning("[beacon] beacon_codec:encode_model/1 NOT found after reload"),
                    nil
            end;
        {error, Reason} ->
            logger:warning("[beacon] Failed to hot-reload beacon_codec: ~p", [Reason]),
            nil
    end.
