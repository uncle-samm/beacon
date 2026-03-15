-module(beacon_middleware_ffi).
-export([http_method_to_string/1, http_options/0]).

http_method_to_string(Method) when is_atom(Method) ->
    string:uppercase(atom_to_binary(Method, utf8));
http_method_to_string(Method) when is_binary(Method) ->
    string:uppercase(Method);
http_method_to_string({other, Method}) when is_binary(Method) ->
    string:uppercase(Method);
http_method_to_string(_) ->
    <<"UNKNOWN">>.

http_options() ->
    options.
