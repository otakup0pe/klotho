-module(klotho_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include("klotho.hrl").
-include_lib("erl_openrouter/include/openrouter.hrl").

-export([all/0, groups/0,
         init_per_suite/1, end_per_suite/1,
         init_per_group/2, end_per_group/2,
         init_per_testcase/2, end_per_testcase/2]).

-export([app_starts_and_stops/1,
         mcp_dependency_is_optional/1,
         supervisor_start_agent/1,
         agent_cleaned_up_after_stop/1,
         agent_one_shot_via_supervisor/1,
         agent_multi_turn_via_supervisor/1]).

all() ->
    [{group, lifecycle},
     {group, supervisor}].

groups() ->
    [{lifecycle, [sequence],
      [app_starts_and_stops,
       mcp_dependency_is_optional]},
     {supervisor, [],
      [supervisor_start_agent,
       agent_cleaned_up_after_stop,
       agent_one_shot_via_supervisor,
       agent_multi_turn_via_supervisor]}].

init_per_suite(Config) ->
    Config.

end_per_suite(_Config) ->
    ok.

init_per_group(lifecycle, Config) ->
    Config;
init_per_group(supervisor, Config) ->
    meck:new(openrouter, [non_strict]),
    {ok, _} = application:ensure_all_started(klotho),
    Config.

end_per_group(lifecycle, _Config) ->
    ok;
end_per_group(supervisor, _Config) ->
    application:stop(klotho),
    meck:unload(openrouter),
    ok.

init_per_testcase(_TC, Config) ->
    Config.

end_per_testcase(_TC, _Config) ->
    ok.

%%--------------------------------------------------------------------
%% Helpers
%%--------------------------------------------------------------------

mock_stop_response(Content) ->
    #chat_response{
        id = <<"resp-ct">>,
        model = <<"test/model">>,
        choices = [#{
            <<"message">> => #{<<"role">> => <<"assistant">>,
                               <<"content">> => Content},
            <<"finish_reason">> => <<"stop">>
        }],
        usage = #{},
        cost = 0.0
    }.

mock_tool_calls_response(ToolCalls) ->
    #chat_response{
        id = <<"resp-tc">>,
        model = <<"test/model">>,
        choices = [#{
            <<"message">> => #{<<"role">> => <<"assistant">>,
                               <<"content">> => null,
                               <<"tool_calls">> => ToolCalls},
            <<"finish_reason">> => <<"tool_calls">>
        }],
        usage = #{},
        cost = 0.0
    }.

make_tool_call(Id, Name, ArgsMap) ->
    #{<<"id">> => Id,
      <<"type">> => <<"function">>,
      <<"function">> => #{<<"name">> => Name,
                          <<"arguments">> => json:encode(ArgsMap)}}.

echo_tool() ->
    #klotho_tool{
        name = <<"echo">>,
        description = <<"Echoes input">>,
        input_schema = #{<<"type">> => <<"object">>,
                         <<"properties">> => #{
                             <<"text">> => #{<<"type">> => <<"string">>}
                         }},
        handler = fun(Args) ->
            {ok, maps:get(<<"text">>, Args, <<>>)}
        end
    }.

base_config() ->
    base_config(<<"Hello">>, []).

base_config(UserMsg, Tools) ->
    #{llm => #{model => <<"test/model">>, temperature => 0.0},
      tools => Tools,
      user_messages => [UserMsg]}.

%%--------------------------------------------------------------------
%% lifecycle group
%%--------------------------------------------------------------------

app_starts_and_stops(_Config) ->
    {ok, _} = application:ensure_all_started(klotho),
    ?assert(is_pid(whereis(klotho_sup))),
    ok = application:stop(klotho),
    ?assertEqual(undefined, whereis(klotho_sup)).

mcp_dependency_is_optional(_Config) ->
    {ok, Required} = application:get_key(klotho, applications),
    {ok, Optional} = application:get_key(klotho, optional_applications),
    ?assert(lists:member(erl_openrouter, Required)),
    ?assertNot(lists:member(erl_mcp, Required)),
    ?assert(lists:member(erl_mcp, Optional)),

    _ = application:stop(erl_mcp),
    ?assertNot(lists:keymember(erl_mcp, 1, application:which_applications())),
    {ok, _} = application:ensure_all_started(klotho),
    ?assertNot(lists:keymember(erl_mcp, 1, application:which_applications())),
    ok = application:stop(klotho).

%%--------------------------------------------------------------------
%% supervisor group
%%--------------------------------------------------------------------

supervisor_start_agent(_Config) ->
    meck:expect(openrouter, chat, fun(_Msgs, _Opts) ->
        {ok, mock_stop_response(<<"Hi">>)}
    end),
    Config = base_config(),
    {ok, Pid} = klotho_sup:start_agent(Config),
    ?assert(is_pid(Pid)),
    ?assert(is_process_alive(Pid)).

agent_cleaned_up_after_stop(_Config) ->
    meck:expect(openrouter, chat, fun(_Msgs, _Opts) ->
        {ok, mock_stop_response(<<"Hi">>)}
    end),
    Config = base_config(),
    {ok, Pid} = klotho_sup:start_agent(Config),
    {ok, _Result} = klotho_agent:run(Pid, 5000),
    ok = klotho_agent:stop(Pid),
    timer:sleep(50),
    ?assertNot(is_process_alive(Pid)).

agent_one_shot_via_supervisor(_Config) ->
    CallCount = counters:new(1, []),
    meck:expect(openrouter, chat, fun(_Msgs, _Opts) ->
        N = counters:get(CallCount, 1),
        counters:add(CallCount, 1, 1),
        case N of
            0 ->
                TC = make_tool_call(<<"tc-1">>, <<"echo">>,
                                    #{<<"text">> => <<"supervised">>}),
                {ok, mock_tool_calls_response([TC])};
            _ ->
                {ok, mock_stop_response(<<"Done: supervised">>)}
        end
    end),
    Config = base_config(<<"Echo supervised">>, [echo_tool()]),
    {ok, Pid} = klotho_sup:start_agent(Config),
    {ok, Result} = klotho_agent:run(Pid, 5000),
    ?assertEqual(ok, Result#klotho_result.status),
    ?assertEqual(<<"Done: supervised">>, Result#klotho_result.message),
    ?assertEqual(1, Result#klotho_result.total_steps),
    ok = klotho_agent:stop(Pid).

agent_multi_turn_via_supervisor(_Config) ->
    CallCount = counters:new(1, []),
    meck:expect(openrouter, chat, fun(_Msgs, _Opts) ->
        N = counters:get(CallCount, 1),
        counters:add(CallCount, 1, 1),
        case N of
            0 -> {ok, mock_stop_response(<<"Turn 1 done">>)};
            1 -> {ok, mock_stop_response(<<"Turn 2 done">>)};
            _ -> {ok, mock_stop_response(<<"Turn 3 done">>)}
        end
    end),
    Config = (base_config())#{max_turns => 5},
    {ok, Pid} = klotho_sup:start_agent(Config),
    {ok, R1} = klotho_agent:run(Pid, 5000),
    ?assertEqual(1, R1#klotho_result.turn_number),
    ?assertEqual(<<"Turn 1 done">>, R1#klotho_result.message),
    {ok, R2} = klotho_agent:resume(Pid, <<"Continue">>),
    ?assertEqual(2, R2#klotho_result.turn_number),
    ?assertEqual(<<"Turn 2 done">>, R2#klotho_result.message),
    {ok, R3} = klotho_agent:resume(Pid, <<"One more">>),
    ?assertEqual(3, R3#klotho_result.turn_number),
    ?assertEqual(<<"Turn 3 done">>, R3#klotho_result.message),
    ok = klotho_agent:stop(Pid).
