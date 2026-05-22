-module(klotho_app).
-behaviour(application).

%% @doc OTP application callback for klotho.

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    klotho_sup:start_link().

stop(_State) ->
    ok.
