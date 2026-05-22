-module(klotho_sup).
-behaviour(supervisor).

%% @doc Top-level supervisor for klotho.
%%
%% Uses simple_one_for_one strategy so consumers can dynamically
%% start klotho_agent workers under this supervisor via
%% klotho_sup:start_agent/1.

-export([start_link/0, start_agent/1]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% @doc Start a klotho_agent worker under this supervisor.
-spec start_agent(map()) -> {ok, pid()} | {error, term()}.
start_agent(Config) ->
    supervisor:start_child(?MODULE, [Config]).

init([]) ->
    SupFlags = #{
        strategy => simple_one_for_one,
        intensity => 5,
        period => 60
    },
    ChildSpec = #{
        id => klotho_agent,
        start => {klotho_agent, start_link, []},
        restart => temporary,
        shutdown => 5000,
        type => worker,
        modules => [klotho_agent]
    },
    {ok, {SupFlags, [ChildSpec]}}.
