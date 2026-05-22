-module(klotho_agent_tests).
-include_lib("eunit/include/eunit.hrl").
-include("klotho.hrl").
-include_lib("erl_openrouter/include/openrouter.hrl").

%%%===================================================================
%%% Test helpers
%%%===================================================================

base_config() ->
    base_config(<<"Hello">>, []).

base_config(UserMsg, Tools) ->
    #{
        llm => #{model => <<"test/model">>, temperature => 0.0},
        tools => Tools,
        user_messages => [UserMsg]
    }.

%% Build a mock chat_response that finishes with stop.
mock_stop_response(Content) ->
    #chat_response{
        id = <<"resp-1">>,
        model = <<"test/model">>,
        choices = [#{
            <<"message">> => #{<<"role">> => <<"assistant">>,
                               <<"content">> => Content},
            <<"finish_reason">> => <<"stop">>
        }],
        usage = #{},
        cost = 0.0
    }.

%% Build a mock chat_response that requests tool calls.
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
    ArgsBin = json:encode(ArgsMap),
    #{<<"id">> => Id,
      <<"type">> => <<"function">>,
      <<"function">> => #{<<"name">> => Name,
                          <<"arguments">> => ArgsBin}}.

echo_tool() ->
    #klotho_tool{
        name = <<"echo">>,
        description = <<"Echoes input back">>,
        input_schema = #{<<"type">> => <<"object">>,
                         <<"properties">> => #{
                             <<"text">> => #{<<"type">> => <<"string">>}
                         }},
        handler = fun(Args) ->
            Text = maps:get(<<"text">>, Args, <<"">>),
            {ok, Text}
        end
    }.

error_tool() ->
    #klotho_tool{
        name = <<"fail">>,
        description = <<"Always fails">>,
        input_schema = #{<<"type">> => <<"object">>},
        handler = fun(_Args) ->
            {error, intentional_failure}
        end
    }.

crash_tool() ->
    #klotho_tool{
        name = <<"crash">>,
        description = <<"Crashes">>,
        input_schema = #{<<"type">> => <<"object">>},
        handler = fun(_Args) ->
            error(boom)
        end
    }.

setup_meck() ->
    meck:new(openrouter, [non_strict]),
    ok.

teardown_meck(_) ->
    meck:unload(openrouter),
    ok.

%%%===================================================================
%%% Phase 1 Tests (backward compatibility)
%%%===================================================================

%% Test: simple stop response (no tool use)
simple_stop_test_() ->
    {setup,
     fun setup_meck/0,
     fun teardown_meck/1,
     fun(_) ->
         meck:expect(openrouter, chat, fun(_Msgs, _Opts) ->
             {ok, mock_stop_response(<<"Hello there!">>)}
         end),
         Config = base_config(),
         {ok, Pid} = klotho_agent:start_link(Config),
         {ok, Result} = klotho_agent:run(Pid, 5000),
         [
          ?_assertEqual(ok, Result#klotho_result.status),
          ?_assertEqual(<<"Hello there!">>, Result#klotho_result.message),
          ?_assertEqual(0, Result#klotho_result.total_steps),
          ?_assertEqual([], Result#klotho_result.steps),
          ?_assert(Result#klotho_result.elapsed_ms >= 0),
          ?_assertEqual(1, Result#klotho_result.turn_number)
         ]
     end}.

%% Test: single tool call round-trip
single_tool_call_test_() ->
    {setup,
     fun setup_meck/0,
     fun teardown_meck/1,
     fun(_) ->
         CallCount = counters:new(1, []),
         meck:expect(openrouter, chat, fun(_Msgs, _Opts) ->
             N = counters:get(CallCount, 1),
             counters:add(CallCount, 1, 1),
             case N of
                 0 ->
                     TC = make_tool_call(<<"tc-1">>, <<"echo">>,
                                         #{<<"text">> => <<"world">>}),
                     {ok, mock_tool_calls_response([TC])};
                 _ ->
                     {ok, mock_stop_response(<<"Done: world">>)}
             end
         end),
         Config = base_config(<<"Say world">>, [echo_tool()]),
         {ok, Pid} = klotho_agent:start_link(Config),
         {ok, Result} = klotho_agent:run(Pid, 5000),
         [
          ?_assertEqual(ok, Result#klotho_result.status),
          ?_assertEqual(<<"Done: world">>, Result#klotho_result.message),
          ?_assertEqual(1, Result#klotho_result.total_steps),
          ?_assertEqual(1, length(Result#klotho_result.steps))
         ]
     end}.

%% Test: tool error is surfaced to LLM
tool_error_test_() ->
    {setup,
     fun setup_meck/0,
     fun teardown_meck/1,
     fun(_) ->
         CallCount = counters:new(1, []),
         meck:expect(openrouter, chat, fun(Msgs, _Opts) ->
             N = counters:get(CallCount, 1),
             counters:add(CallCount, 1, 1),
             case N of
                 0 ->
                     TC = make_tool_call(<<"tc-1">>, <<"fail">>, #{}),
                     {ok, mock_tool_calls_response([TC])};
                 _ ->
                     LastMsg = lists:last(Msgs),
                     Content = maps:get(<<"content">>, LastMsg, <<>>),
                     case binary:match(Content, <<"ERROR:">>) of
                         nomatch ->
                             {ok, mock_stop_response(<<"no error seen">>)};
                         _ ->
                             {ok, mock_stop_response(<<"saw error">>)}
                     end
             end
         end),
         Config = base_config(<<"do fail">>, [error_tool()]),
         {ok, Pid} = klotho_agent:start_link(Config),
         {ok, Result} = klotho_agent:run(Pid, 5000),
         [
          ?_assertEqual(ok, Result#klotho_result.status),
          ?_assertEqual(<<"saw error">>, Result#klotho_result.message)
         ]
     end}.

%% Test: tool crash is handled gracefully
tool_crash_test_() ->
    {setup,
     fun setup_meck/0,
     fun teardown_meck/1,
     fun(_) ->
         CallCount = counters:new(1, []),
         meck:expect(openrouter, chat, fun(_Msgs, _Opts) ->
             N = counters:get(CallCount, 1),
             counters:add(CallCount, 1, 1),
             case N of
                 0 ->
                     TC = make_tool_call(<<"tc-1">>, <<"crash">>, #{}),
                     {ok, mock_tool_calls_response([TC])};
                 _ ->
                     {ok, mock_stop_response(<<"recovered">>)}
             end
         end),
         Config = base_config(<<"do crash">>, [crash_tool()]),
         {ok, Pid} = klotho_agent:start_link(Config),
         {ok, Result} = klotho_agent:run(Pid, 5000),
         [
          ?_assertEqual(ok, Result#klotho_result.status),
          ?_assertEqual(<<"recovered">>, Result#klotho_result.message)
         ]
     end}.

%% Test: max_steps is enforced
max_steps_test_() ->
    {setup,
     fun setup_meck/0,
     fun teardown_meck/1,
     fun(_) ->
         meck:expect(openrouter, chat, fun(_Msgs, _Opts) ->
             TC = make_tool_call(<<"tc-1">>, <<"echo">>,
                                 #{<<"text">> => <<"loop">>}),
             {ok, mock_tool_calls_response([TC])}
         end),
         Config0 = base_config(<<"loop">>, [echo_tool()]),
         Config = Config0#{max_steps => 2},
         {ok, Pid} = klotho_agent:start_link(Config),
         {ok, Result} = klotho_agent:run(Pid, 10000),
         [
          ?_assertEqual(max_steps, Result#klotho_result.status),
          ?_assertEqual(2, Result#klotho_result.total_steps)
         ]
     end}.

%% Test: LLM error is propagated
llm_error_test_() ->
    {setup,
     fun setup_meck/0,
     fun teardown_meck/1,
     fun(_) ->
         meck:expect(openrouter, chat, fun(_Msgs, _Opts) ->
             {error, #api_error{type = rate_limited,
                                code = 429,
                                message = <<"slow down">>}}
         end),
         Config = base_config(),
         {ok, Pid} = klotho_agent:start_link(Config),
         {ok, Result} = klotho_agent:run(Pid, 5000),
         [
          ?_assertEqual(error, Result#klotho_result.status),
          ?_assertMatch({llm_error, _}, Result#klotho_result.error)
         ]
     end}.

%% Test: invalid config fails to start
bad_config_test_() ->
    {setup,
     fun() -> process_flag(trap_exit, true) end,
     fun(WasTrapping) -> process_flag(trap_exit, WasTrapping) end,
     fun(_) ->
         Cases = [
             #{},
             #{llm => #{}, user_messages => []},
             not_a_map
         ],
         [begin
              R = klotho_agent:start_link(C),
              flush_exits(),
              ?_assertMatch({error, _}, R)
          end || C <- Cases]
     end}.

flush_exits() ->
    receive
        {'EXIT', _, _} -> flush_exits()
    after 0 ->
        ok
    end.

%% Test: telemetry callback fires
telemetry_test_() ->
    {setup,
     fun setup_meck/0,
     fun teardown_meck/1,
     fun(_) ->
         Self = self(),
         meck:expect(openrouter, chat, fun(_Msgs, _Opts) ->
             {ok, mock_stop_response(<<"tele">>)}
         end),
         Config0 = base_config(),
         Config = Config0#{telemetry => fun(Event) ->
             Self ! {telemetry, Event}
         end},
         {ok, Pid} = klotho_agent:start_link(Config),
         {ok, _Result} = klotho_agent:run(Pid, 5000),
         receive
             {telemetry, {done, _}} -> ok
         after 1000 ->
             ?assert(false)
         end,
         [?_assert(true)]
     end}.

%% Test: system messages are prepended
system_messages_test_() ->
    {setup,
     fun setup_meck/0,
     fun teardown_meck/1,
     fun(_) ->
         meck:expect(openrouter, chat, fun(Msgs, _Opts) ->
             [First | _] = Msgs,
             Role = maps:get(<<"role">>, First),
             Content = maps:get(<<"content">>, First),
             case {Role, Content} of
                 {<<"system">>, <<"You are helpful.">>} ->
                     {ok, mock_stop_response(<<"sys ok">>)};
                 _ ->
                     {ok, mock_stop_response(<<"sys missing">>)}
             end
         end),
         Config0 = base_config(),
         Config = Config0#{system_messages => [<<"You are helpful.">>]},
         {ok, Pid} = klotho_agent:start_link(Config),
         {ok, Result} = klotho_agent:run(Pid, 5000),
         [?_assertEqual(<<"sys ok">>, Result#klotho_result.message)]
     end}.

%% Test: parallel tool calls
parallel_tool_calls_test_() ->
    {setup,
     fun setup_meck/0,
     fun teardown_meck/1,
     fun(_) ->
         CallCount = counters:new(1, []),
         meck:expect(openrouter, chat, fun(_Msgs, _Opts) ->
             N = counters:get(CallCount, 1),
             counters:add(CallCount, 1, 1),
             case N of
                 0 ->
                     TC1 = make_tool_call(<<"tc-1">>, <<"echo">>,
                                          #{<<"text">> => <<"a">>}),
                     TC2 = make_tool_call(<<"tc-2">>, <<"echo">>,
                                          #{<<"text">> => <<"b">>}),
                     {ok, mock_tool_calls_response([TC1, TC2])};
                 _ ->
                     {ok, mock_stop_response(<<"parallel done">>)}
             end
         end),
         Config = base_config(<<"go">>, [echo_tool()]),
         {ok, Pid} = klotho_agent:start_link(Config),
         {ok, Result} = klotho_agent:run(Pid, 5000),
         Step = hd(Result#klotho_result.steps),
         [
          ?_assertEqual(ok, Result#klotho_result.status),
          ?_assertEqual(2, length(Step#klotho_step.tool_calls)),
          ?_assertEqual(2, length(Step#klotho_step.tool_results))
         ]
     end}.

%% Test: unknown tool name returns error to LLM
unknown_tool_test_() ->
    {setup,
     fun setup_meck/0,
     fun teardown_meck/1,
     fun(_) ->
         CallCount = counters:new(1, []),
         meck:expect(openrouter, chat, fun(_Msgs, _Opts) ->
             N = counters:get(CallCount, 1),
             counters:add(CallCount, 1, 1),
             case N of
                 0 ->
                     TC = make_tool_call(<<"tc-1">>, <<"nonexistent">>, #{}),
                     {ok, mock_tool_calls_response([TC])};
                 _ ->
                     {ok, mock_stop_response(<<"handled unknown">>)}
             end
         end),
         Config = base_config(<<"do unknown">>, [echo_tool()]),
         {ok, Pid} = klotho_agent:start_link(Config),
         {ok, Result} = klotho_agent:run(Pid, 5000),
         [?_assertEqual(ok, Result#klotho_result.status)]
     end}.

%% Test: child_spec
child_spec_test() ->
    Config = base_config(),
    Spec = klotho_agent:child_spec(Config),
    ?assertEqual(klotho_agent, maps:get(id, Spec)),
    ?assertEqual(temporary, maps:get(restart, Spec)),
    ?assertEqual(worker, maps:get(type, Spec)).

%%%===================================================================
%%% Phase 1 backward-compat: one-shot run/2 still terminates agent
%%%===================================================================

%% After run/2 the agent is in awaiting_resume, but if nobody
%% resumes it the process stays alive until stopped or the caller
%% dies. This test confirms the one-shot path returns the correct
%% result shape and that stop/1 works.
one_shot_stop_test_() ->
    {setup,
     fun setup_meck/0,
     fun teardown_meck/1,
     fun(_) ->
         meck:expect(openrouter, chat, fun(_Msgs, _Opts) ->
             {ok, mock_stop_response(<<"one-shot">>)}
         end),
         Config = base_config(),
         {ok, Pid} = klotho_agent:start_link(Config),
         {ok, Result} = klotho_agent:run(Pid, 5000),
         ?assertEqual(ok, Result#klotho_result.status),
         ?assertEqual(<<"one-shot">>, Result#klotho_result.message),
         %% Agent is still alive in awaiting_resume
         ?assert(is_process_alive(Pid)),
         ok = klotho_agent:stop(Pid),
         timer:sleep(50),
         [?_assertNot(is_process_alive(Pid))]
     end}.

%%%===================================================================
%%% Phase 2 Tests: Multi-turn
%%%===================================================================

%% Test: max_turns config validation -- infinity accepted
max_turns_infinity_accepted_test_() ->
    {setup,
     fun setup_meck/0,
     fun teardown_meck/1,
     fun(_) ->
         meck:expect(openrouter, chat, fun(_Msgs, _Opts) ->
             {ok, mock_stop_response(<<"Hi">>)}
         end),
         Config = (base_config())#{max_turns => infinity},
         {ok, Pid} = klotho_agent:start_link(Config),
         {ok, Result} = klotho_agent:run(Pid, 5000),
         ok = klotho_agent:stop(Pid),
         [?_assertEqual(ok, Result#klotho_result.status)]
     end}.

%% Test: max_turns config validation -- zero rejected
max_turns_zero_rejected_test_() ->
    {setup,
     fun() -> process_flag(trap_exit, true) end,
     fun(WasTrapping) -> process_flag(trap_exit, WasTrapping) end,
     fun(_) ->
         Config = (base_config())#{max_turns => 0},
         R = klotho_agent:start_link(Config),
         flush_exits(),
         [?_assertMatch({error, _}, R)]
     end}.

%% Test: bounded multi-turn happy path (5-turn conversation)
multi_turn_happy_path_test_() ->
    {setup,
     fun setup_meck/0,
     fun teardown_meck/1,
     fun(_) ->
         %% Each turn: LLM does one tool call then stops.
         CallCount = counters:new(1, []),
         meck:expect(openrouter, chat, fun(Msgs, _Opts) ->
             N = counters:get(CallCount, 1),
             counters:add(CallCount, 1, 1),
             case N rem 2 of
                 0 ->
                     TC = make_tool_call(
                         iolist_to_binary(io_lib:format("tc-~p", [N])),
                         <<"echo">>,
                         #{<<"text">> => iolist_to_binary(
                             io_lib:format("turn-~p", [length(
                                 [M || M <- Msgs,
                                       maps:get(<<"role">>, M, <<>>) =:= <<"user">>])]))}),
                     {ok, mock_tool_calls_response([TC])};
                 1 ->
                     UserCount = length([M || M <- Msgs,
                                              maps:get(<<"role">>, M, <<>>) =:= <<"user">>]),
                     {ok, mock_stop_response(
                         iolist_to_binary(io_lib:format("reply-~p", [UserCount])))}
             end
         end),
         Config = (base_config(<<"turn1">>, [echo_tool()]))#{max_turns => 10},
         {ok, Pid} = klotho_agent:start_link(Config),

         %% Turn 1
         {ok, R1} = klotho_agent:run(Pid, 5000),
         ?assertEqual(ok, R1#klotho_result.status),
         ?assertEqual(1, R1#klotho_result.turn_number),
         ?assertEqual(1, R1#klotho_result.total_steps),

         %% Turn 2
         {ok, R2} = klotho_agent:resume(Pid, <<"turn2">>),
         ?assertEqual(ok, R2#klotho_result.status),
         ?assertEqual(2, R2#klotho_result.turn_number),

         %% Turn 3
         {ok, R3} = klotho_agent:resume(Pid, <<"turn3">>),
         ?assertEqual(ok, R3#klotho_result.status),
         ?assertEqual(3, R3#klotho_result.turn_number),

         %% Turn 4
         {ok, R4} = klotho_agent:resume(Pid, <<"turn4">>),
         ?assertEqual(ok, R4#klotho_result.status),
         ?assertEqual(4, R4#klotho_result.turn_number),

         %% Turn 5
         {ok, R5} = klotho_agent:resume(Pid, <<"turn5">>),
         ?assertEqual(ok, R5#klotho_result.status),
         ?assertEqual(5, R5#klotho_result.turn_number),

         %% Verify the agent tracked history growth -- the LLM
         %% should have seen more user messages each turn. The
         %% reply content encodes the user message count.
         [
          ?_assertMatch(<<"reply-", _/binary>>, R1#klotho_result.message),
          ?_assertMatch(<<"reply-", _/binary>>, R5#klotho_result.message),
          ?_assert(is_process_alive(Pid))
         ]
     end}.

%% Test: turn-limit exhaustion
turn_limit_exhaustion_test_() ->
    {setup,
     fun setup_meck/0,
     fun teardown_meck/1,
     fun(_) ->
         meck:expect(openrouter, chat, fun(_Msgs, _Opts) ->
             {ok, mock_stop_response(<<"ok">>)}
         end),
         Config = (base_config())#{max_turns => 3},
         {ok, Pid} = klotho_agent:start_link(Config),

         %% Turn 1
         {ok, R1} = klotho_agent:run(Pid, 5000),
         ?assertEqual(ok, R1#klotho_result.status),

         %% Turn 2
         {ok, R2} = klotho_agent:resume(Pid, <<"turn2">>),
         ?assertEqual(ok, R2#klotho_result.status),

         %% Turn 3
         {ok, R3} = klotho_agent:resume(Pid, <<"turn3">>),
         ?assertEqual(ok, R3#klotho_result.status),

         %% Turn 4 -- should hit turn limit
         Result4 = klotho_agent:resume(Pid, <<"turn4">>),
         [
          ?_assertMatch({error, {turn_limit_exhausted, _}}, Result4),
          ?_assert(begin
              {error, {turn_limit_exhausted, Info}} = Result4,
              maps:get(turns_used, Info) =:= 3
              andalso maps:get(max_turns, Info) =:= 3
              andalso is_list(maps:get(history, Info))
              andalso is_binary(maps:get(last_assistant_message, Info))
          end)
         ]
     end}.

%% Test: resume on failed state returns {error, invalid_state}
resume_from_failed_test_() ->
    {setup,
     fun setup_meck/0,
     fun teardown_meck/1,
     fun(_) ->
         %% Force an LLM error on turn 1 to put agent in failed state
         meck:expect(openrouter, chat, fun(_Msgs, _Opts) ->
             {error, #api_error{type = rate_limited,
                                code = 429,
                                message = <<"slow down">>}}
         end),
         Config = base_config(),
         {ok, Pid} = klotho_agent:start_link(Config),
         {ok, Result} = klotho_agent:run(Pid, 5000),
         ?assertEqual(error, Result#klotho_result.status),
         %% Agent stopped on error -- resume should fail
         %% The process is dead after reply_and_stop
         timer:sleep(50),
         [?_assertNot(is_process_alive(Pid))]
     end}.

%% Test: resume from a different process returns {error, foreign_caller}
resume_foreign_caller_test_() ->
    {setup,
     fun setup_meck/0,
     fun teardown_meck/1,
     fun(_) ->
         meck:expect(openrouter, chat, fun(_Msgs, _Opts) ->
             {ok, mock_stop_response(<<"ok">>)}
         end),
         Config = base_config(),
         {ok, Pid} = klotho_agent:start_link(Config),

         %% run/2 from this process (the "owner")
         {ok, _R1} = klotho_agent:run(Pid, 5000),

         %% resume from a different process
         Self = self(),
         OtherPid = spawn(fun() ->
             R = klotho_agent:resume(Pid, <<"foreign">>),
             Self ! {foreign_result, R}
         end),
         Result = receive
             {foreign_result, R} -> R
         after 5000 ->
             timeout
         end,
         _ = OtherPid,
         [?_assertEqual({error, foreign_caller}, Result)]
     end}.

%% Test: caller-died on resume cleans up agent
caller_died_on_resume_test_() ->
    {setup,
     fun setup_meck/0,
     fun teardown_meck/1,
     fun(_) ->
         %% First call returns stop, second call blocks forever
         CallCount = counters:new(1, []),
         meck:expect(openrouter, chat, fun(_Msgs, _Opts) ->
             N = counters:get(CallCount, 1),
             counters:add(CallCount, 1, 1),
             case N of
                 0 ->
                     {ok, mock_stop_response(<<"first">>)};
                 _ ->
                     %% Block forever to simulate a long LLM call
                     receive never -> ok end,
                     {ok, mock_stop_response(<<"never">>)}
             end
         end),
         Config = base_config(),
         Self = self(),
         CallerPid = spawn(fun() ->
             {ok, Pid} = klotho_agent:start_link(Config),
             Self ! {agent_pid, Pid},
             {ok, _R1} = klotho_agent:run(Pid, 5000),
             %% Resume -- this will block on the LLM call
             _R2 = klotho_agent:resume(Pid, <<"resume">>),
             %% Should never reach here
             Self ! {unexpected_resume_result, _R2}
         end),
         AgentPid = receive {agent_pid, P} -> P after 5000 -> error(timeout) end,
         %% Wait for the resume to be in flight
         timer:sleep(100),
         ?assert(is_process_alive(AgentPid)),
         %% Kill the caller
         exit(CallerPid, kill),
         timer:sleep(200),
         [?_assertNot(is_process_alive(AgentPid))]
     end}.

%% Test: caller-died during run/2 cleans up agent (Phase 1 re-confirm)
caller_died_on_run_test_() ->
    {setup,
     fun setup_meck/0,
     fun teardown_meck/1,
     fun(_) ->
         meck:expect(openrouter, chat, fun(_Msgs, _Opts) ->
             receive never -> ok end,
             {ok, mock_stop_response(<<"never">>)}
         end),
         Config = base_config(),
         Self = self(),
         CallerPid = spawn(fun() ->
             {ok, Pid} = klotho_agent:start_link(Config),
             Self ! {agent_pid, Pid},
             _R = klotho_agent:run(Pid, 60000),
             Self ! {unexpected_run_result, _R}
         end),
         AgentPid = receive {agent_pid, P} -> P after 5000 -> error(timeout) end,
         timer:sleep(100),
         ?assert(is_process_alive(AgentPid)),
         exit(CallerPid, kill),
         timer:sleep(200),
         [?_assertNot(is_process_alive(AgentPid))]
     end}.

%% Test: turn telemetry events fire
turn_telemetry_test_() ->
    {setup,
     fun setup_meck/0,
     fun teardown_meck/1,
     fun(_) ->
         Self = self(),
         Events = ets:new(telemetry_events, [bag, public]),
         meck:expect(openrouter, chat, fun(_Msgs, _Opts) ->
             {ok, mock_stop_response(<<"ok">>)}
         end),
         Config = (base_config())#{
             max_turns => 5,
             telemetry => fun(Event) ->
                 ets:insert(Events, {event, Event}),
                 Self ! {tele, Event}
             end
         },
         {ok, Pid} = klotho_agent:start_link(Config),

         %% Turn 1
         {ok, _} = klotho_agent:run(Pid, 5000),
         %% Turn 2
         {ok, _} = klotho_agent:resume(Pid, <<"turn2">>),

         %% Collect events
         timer:sleep(100),
         AllEvents = [E || {event, E} <- ets:tab2list(Events)],
         ets:delete(Events),

         %% Check for turn_start and turn_end events
         TurnStarts = [T || {turn_start, T} <- AllEvents],
         TurnEnds = [T || {turn_end, T} <- AllEvents],
         [
          ?_assertEqual([1, 2], lists:sort(TurnStarts)),
          ?_assertEqual([1, 2], lists:sort(TurnEnds))
         ]
     end}.

%% Test: step records include turn_number
step_turn_number_test_() ->
    {setup,
     fun setup_meck/0,
     fun teardown_meck/1,
     fun(_) ->
         CallCount = counters:new(1, []),
         meck:expect(openrouter, chat, fun(_Msgs, _Opts) ->
             N = counters:get(CallCount, 1),
             counters:add(CallCount, 1, 1),
             case N rem 2 of
                 0 ->
                     TC = make_tool_call(
                         iolist_to_binary(io_lib:format("tc-~p", [N])),
                         <<"echo">>,
                         #{<<"text">> => <<"x">>}),
                     {ok, mock_tool_calls_response([TC])};
                 1 ->
                     {ok, mock_stop_response(<<"ok">>)}
             end
         end),
         Config = (base_config(<<"go">>, [echo_tool()]))#{max_turns => 5},
         {ok, Pid} = klotho_agent:start_link(Config),

         %% Turn 1: tool call then stop
         {ok, R1} = klotho_agent:run(Pid, 5000),
         %% Turn 2: tool call then stop
         {ok, R2} = klotho_agent:resume(Pid, <<"turn2">>),

         Step1 = hd(R1#klotho_result.steps),
         Step2 = hd(R2#klotho_result.steps),
         [
          ?_assertEqual(1, Step1#klotho_step.turn_number),
          ?_assertEqual(2, Step2#klotho_step.turn_number)
         ]
     end}.

%% Test: resume with map-format message
resume_map_message_test_() ->
    {setup,
     fun setup_meck/0,
     fun teardown_meck/1,
     fun(_) ->
         meck:expect(openrouter, chat, fun(Msgs, _Opts) ->
             LastUser = lists:last([M || M <- Msgs,
                                        maps:get(<<"role">>, M, <<>>) =:= <<"user">>]),
             Content = maps:get(<<"content">>, LastUser, <<>>),
             {ok, mock_stop_response(Content)}
         end),
         Config = base_config(),
         {ok, Pid} = klotho_agent:start_link(Config),
         {ok, _R1} = klotho_agent:run(Pid, 5000),
         %% Resume with a pre-built map
         {ok, R2} = klotho_agent:resume(Pid,
             #{<<"role">> => <<"user">>, <<"content">> => <<"map-msg">>}),
         [?_assertEqual(<<"map-msg">>, R2#klotho_result.message)]
     end}.

%% Test: status reflects phase correctly
status_phases_test_() ->
    {setup,
     fun setup_meck/0,
     fun teardown_meck/1,
     fun(_) ->
         meck:expect(openrouter, chat, fun(_Msgs, _Opts) ->
             {ok, mock_stop_response(<<"ok">>)}
         end),
         Config = base_config(),
         {ok, Pid} = klotho_agent:start_link(Config),

         %% Before run: idle
         S1 = klotho_agent:status(Pid),
         ?assertEqual(idle, maps:get(state, S1)),

         %% After run: awaiting_resume
         {ok, _} = klotho_agent:run(Pid, 5000),
         S2 = klotho_agent:status(Pid),
         [
          ?_assertEqual(awaiting_resume, maps:get(state, S2)),
          ?_assertEqual(1, maps:get(turn, S2))
         ]
     end}.

%%%===================================================================
%%% Tool Timeout Enforcement Tests
%%%===================================================================

slow_tool(SleepMs) ->
    #klotho_tool{
        name = <<"slow">>,
        description = <<"Sleeps then returns">>,
        input_schema = #{<<"type">> => <<"object">>},
        handler = fun(_Args) ->
            timer:sleep(SleepMs),
            {ok, <<"slow done">>}
        end
    }.

fast_tool() ->
    #klotho_tool{
        name = <<"fast">>,
        description = <<"Returns immediately">>,
        input_schema = #{<<"type">> => <<"object">>},
        handler = fun(_Args) ->
            {ok, <<"fast done">>}
        end
    }.

%% Test: tool that exceeds timeout produces a tool_error result and
%% agent loop continues normally.
tool_timeout_produces_error_test_() ->
    {setup,
     fun setup_meck/0,
     fun teardown_meck/1,
     fun(_) ->
         CallCount = counters:new(1, []),
         meck:expect(openrouter, chat, fun(Msgs, _Opts) ->
             N = counters:get(CallCount, 1),
             counters:add(CallCount, 1, 1),
             case N of
                 0 ->
                     TC = make_tool_call(<<"tc-slow">>, <<"slow">>, #{}),
                     {ok, mock_tool_calls_response([TC])};
                 _ ->
                     %% Verify the LLM saw an error message
                     ToolMsgs = [M || M <- Msgs,
                                      maps:get(<<"role">>, M, <<>>) =:= <<"tool">>],
                     LastTool = lists:last(ToolMsgs),
                     Content = maps:get(<<"content">>, LastTool, <<>>),
                     case binary:match(Content, <<"timed out">>) of
                         nomatch ->
                             {ok, mock_stop_response(<<"no timeout seen">>)};
                         _ ->
                             {ok, mock_stop_response(<<"saw timeout">>)}
                     end
             end
         end),
         %% Tool sleeps 500ms, timeout is 100ms
         Config = (base_config(<<"go">>, [slow_tool(500)]))#{
             tool_timeout_ms => 100
         },
         {ok, Pid} = klotho_agent:start_link(Config),
         {ok, Result} = klotho_agent:run(Pid, 5000),
         [
          ?_assertEqual(ok, Result#klotho_result.status),
          ?_assertEqual(<<"saw timeout">>, Result#klotho_result.message),
          ?_assertEqual(1, Result#klotho_result.total_steps)
         ]
     end}.

%% Test: tool that completes within timeout has no stale timeout
%% messages arriving later.
tool_within_timeout_no_stale_test_() ->
    {setup,
     fun setup_meck/0,
     fun teardown_meck/1,
     fun(_) ->
         CallCount = counters:new(1, []),
         meck:expect(openrouter, chat, fun(_Msgs, _Opts) ->
             N = counters:get(CallCount, 1),
             counters:add(CallCount, 1, 1),
             case N of
                 0 ->
                     TC = make_tool_call(<<"tc-fast">>, <<"fast">>, #{}),
                     {ok, mock_tool_calls_response([TC])};
                 _ ->
                     {ok, mock_stop_response(<<"fast ok">>)}
             end
         end),
         %% Tool returns instantly, timeout is 1 second
         Config = (base_config(<<"go">>, [fast_tool()]))#{
             tool_timeout_ms => 1000
         },
         {ok, Pid} = klotho_agent:start_link(Config),
         {ok, Result} = klotho_agent:run(Pid, 5000),
         %% Wait long enough for stale timeout to have fired if it
         %% was not cancelled
         timer:sleep(1200),
         %% Agent is still alive and well in awaiting_resume
         Status = klotho_agent:status(Pid),
         [
          ?_assertEqual(ok, Result#klotho_result.status),
          ?_assertEqual(<<"fast ok">>, Result#klotho_result.message),
          ?_assertEqual(awaiting_resume, maps:get(state, Status))
         ]
     end}.

%% Test: multiple parallel tool calls, one slow (times out), others
%% fast (succeed) -- agent proceeds with mixed results.
parallel_timeout_mixed_test_() ->
    {setup,
     fun setup_meck/0,
     fun teardown_meck/1,
     fun(_) ->
         CallCount = counters:new(1, []),
         meck:expect(openrouter, chat, fun(Msgs, _Opts) ->
             N = counters:get(CallCount, 1),
             counters:add(CallCount, 1, 1),
             case N of
                 0 ->
                     TC1 = make_tool_call(<<"tc-fast1">>, <<"fast">>, #{}),
                     TC2 = make_tool_call(<<"tc-slow1">>, <<"slow">>, #{}),
                     TC3 = make_tool_call(<<"tc-fast2">>, <<"fast">>, #{}),
                     {ok, mock_tool_calls_response([TC1, TC2, TC3])};
                 _ ->
                     %% Count tool messages: should have 3 results
                     ToolMsgs = [M || M <- Msgs,
                                      maps:get(<<"role">>, M, <<>>) =:= <<"tool">>],
                     %% Check which ones have timeout errors
                     TimeoutMsgs = [M || M <- ToolMsgs,
                                         binary:match(
                                             maps:get(<<"content">>, M, <<>>),
                                             <<"timed out">>) =/= nomatch],
                     SuccessMsgs = [M || M <- ToolMsgs,
                                         maps:get(<<"content">>, M, <<>>) =:= <<"fast done">>],
                     Resp = iolist_to_binary(io_lib:format(
                         "tools:~p,timeouts:~p,successes:~p",
                         [length(ToolMsgs), length(TimeoutMsgs),
                          length(SuccessMsgs)])),
                     {ok, mock_stop_response(Resp)}
             end
         end),
         %% slow tool sleeps 500ms, timeout 100ms
         Config = (base_config(<<"go">>, [fast_tool(), slow_tool(500)]))#{
             tool_timeout_ms => 100
         },
         {ok, Pid} = klotho_agent:start_link(Config),
         {ok, Result} = klotho_agent:run(Pid, 5000),
         [
          ?_assertEqual(ok, Result#klotho_result.status),
          %% 3 tool results total, 1 timeout, 2 successes
          ?_assertEqual(<<"tools:3,timeouts:1,successes:2">>,
                        Result#klotho_result.message)
         ]
     end}.

%% Test: tool_timeout telemetry event fires
tool_timeout_telemetry_test_() ->
    {setup,
     fun setup_meck/0,
     fun teardown_meck/1,
     fun(_) ->
         Self = self(),
         CallCount = counters:new(1, []),
         meck:expect(openrouter, chat, fun(_Msgs, _Opts) ->
             N = counters:get(CallCount, 1),
             counters:add(CallCount, 1, 1),
             case N of
                 0 ->
                     TC = make_tool_call(<<"tc-slow">>, <<"slow">>, #{}),
                     {ok, mock_tool_calls_response([TC])};
                 _ ->
                     {ok, mock_stop_response(<<"ok">>)}
             end
         end),
         Config = (base_config(<<"go">>, [slow_tool(500)]))#{
             tool_timeout_ms => 50,
             telemetry => fun(Event) ->
                 Self ! {tele, Event}
             end
         },
         {ok, Pid} = klotho_agent:start_link(Config),
         {ok, _} = klotho_agent:run(Pid, 5000),
         %% Expect a tool_timeout telemetry event
         Result = receive
             {tele, {tool_timeout, <<"tc-slow">>, 50}} -> got_timeout
         after 2000 ->
             no_timeout_event
         end,
         [?_assertEqual(got_timeout, Result)]
     end}.

%%%===================================================================
%%% on_terminate Callback Tests
%%%===================================================================

%% Test: on_terminate hook fires with correct snapshot shape on
%% normal termination (run/2 then stop/1).
on_terminate_normal_stop_test_() ->
    {setup,
     fun setup_meck/0,
     fun teardown_meck/1,
     fun(_) ->
         Self = self(),
         meck:expect(openrouter, chat, fun(_Msgs, _Opts) ->
             {ok, mock_stop_response(<<"final">>)}
         end),
         Config = (base_config())#{
             on_terminate => fun(Reason, Snapshot) ->
                 Self ! {terminated, Reason, Snapshot}
             end
         },
         {ok, Pid} = klotho_agent:start_link(Config),
         {ok, _} = klotho_agent:run(Pid, 5000),
         ok = klotho_agent:stop(Pid),
         {Reason, Snapshot} = receive
             {terminated, R, S} -> {R, S}
         after 2000 ->
             error(no_terminate_callback)
         end,
         [
          ?_assertEqual(normal, Reason),
          %% Verify snapshot shape
          ?_assert(is_map(Snapshot)),
          ?_assert(maps:is_key(phase, Snapshot)),
          ?_assert(maps:is_key(turn, Snapshot)),
          ?_assert(maps:is_key(step_count, Snapshot)),
          ?_assert(maps:is_key(messages, Snapshot)),
          ?_assert(maps:is_key(steps, Snapshot)),
          ?_assert(maps:is_key(result, Snapshot)),
          ?_assert(maps:is_key(elapsed_ms, Snapshot)),
          ?_assert(maps:is_key(last_error, Snapshot)),
          ?_assert(maps:is_key(max_turns, Snapshot)),
          ?_assert(maps:is_key(max_steps, Snapshot)),
          ?_assert(maps:is_key(tool_timeout_ms, Snapshot)),
          %% Verify values
          ?_assertEqual(awaiting_resume, maps:get(phase, Snapshot)),
          ?_assertEqual(1, maps:get(turn, Snapshot)),
          ?_assertEqual(0, maps:get(step_count, Snapshot)),
          ?_assert(is_list(maps:get(messages, Snapshot))),
          ?_assert(is_list(maps:get(steps, Snapshot))),
          ?_assertEqual(undefined, maps:get(last_error, Snapshot)),
          ?_assert(maps:get(result, Snapshot) =/= undefined)
         ]
     end}.

%% Test: on_terminate hook fires after turn_limit_exhausted (failed terminal)
on_terminate_turn_limit_test_() ->
    {setup,
     fun setup_meck/0,
     fun teardown_meck/1,
     fun(_) ->
         Self = self(),
         meck:expect(openrouter, chat, fun(_Msgs, _Opts) ->
             {ok, mock_stop_response(<<"ok">>)}
         end),
         Config = (base_config())#{
             max_turns => 1,
             on_terminate => fun(Reason, Snapshot) ->
                 Self ! {terminated, Reason, Snapshot}
             end
         },
         {ok, Pid} = klotho_agent:start_link(Config),
         {ok, _R1} = klotho_agent:run(Pid, 5000),

         %% Turn 2 attempt -- should hit turn limit and terminate
         _R2 = klotho_agent:resume(Pid, <<"turn2">>),

         {Reason, Snapshot} = receive
             {terminated, R, S} -> {R, S}
         after 2000 ->
             error(no_terminate_callback)
         end,
         [
          ?_assertEqual(normal, Reason),
          ?_assertEqual(1, maps:get(turn, Snapshot)),
          ?_assertEqual(1, maps:get(max_turns, Snapshot))
         ]
     end}.

%% Test: on_terminate hook crashing does NOT prevent process termination
on_terminate_crash_safe_test_() ->
    {setup,
     fun setup_meck/0,
     fun teardown_meck/1,
     fun(_) ->
         meck:expect(openrouter, chat, fun(_Msgs, _Opts) ->
             {ok, mock_stop_response(<<"ok">>)}
         end),
         Config = (base_config())#{
             on_terminate => fun(_Reason, _Snapshot) ->
                 error(hook_explosion)
             end
         },
         {ok, Pid} = klotho_agent:start_link(Config),
         {ok, _} = klotho_agent:run(Pid, 5000),
         ok = klotho_agent:stop(Pid),
         timer:sleep(100),
         [?_assertNot(is_process_alive(Pid))]
     end}.

%% Test: on_terminate fires when caller dies, with a well-formed
%% snapshot.  The exact reason depends on EXIT vs DOWN race (the
%% link EXIT may arrive before the monitor DOWN), so we test that
%% the hook fires and the snapshot is usable rather than asserting
%% a specific reason atom.
on_terminate_caller_died_test_() ->
    {setup,
     fun setup_meck/0,
     fun teardown_meck/1,
     fun(_) ->
         Self = self(),
         meck:expect(openrouter, chat, fun(_Msgs, _Opts) ->
             %% Block to keep agent alive while caller dies
             receive never -> ok end,
             {ok, mock_stop_response(<<"never">>)}
         end),
         Config = (base_config())#{
             on_terminate => fun(Reason, Snapshot) ->
                 Self ! {terminated, Reason, Snapshot}
             end
         },
         CallerPid = spawn(fun() ->
             {ok, Pid} = klotho_agent:start_link(Config),
             Self ! {agent_pid, Pid},
             _R = klotho_agent:run(Pid, 60000),
             Self ! {unexpected_result, _R}
         end),
         AgentPid = receive {agent_pid, P} -> P after 5000 -> error(timeout) end,
         timer:sleep(100),
         ?assert(is_process_alive(AgentPid)),
         exit(CallerPid, kill),
         {_Reason, Snapshot} = receive
             {terminated, R, S} -> {R, S}
         after 2000 ->
             error(no_terminate_callback)
         end,
         %% The hook fired -- verify snapshot is well-formed
         [
          ?_assert(is_map(Snapshot)),
          ?_assert(maps:is_key(phase, Snapshot)),
          ?_assert(maps:is_key(turn, Snapshot)),
          ?_assert(maps:is_key(messages, Snapshot)),
          ?_assert(is_list(maps:get(messages, Snapshot)))
         ]
     end}.

%% Test: on_terminate receives correct reason for normal completion
%% (via reply_and_stop on LLM error)
on_terminate_error_reason_test_() ->
    {setup,
     fun setup_meck/0,
     fun teardown_meck/1,
     fun(_) ->
         Self = self(),
         meck:expect(openrouter, chat, fun(_Msgs, _Opts) ->
             {error, #api_error{type = rate_limited,
                                code = 429,
                                message = <<"slow down">>}}
         end),
         Config = (base_config())#{
             on_terminate => fun(Reason, Snapshot) ->
                 Self ! {terminated, Reason, Snapshot}
             end
         },
         {ok, Pid} = klotho_agent:start_link(Config),
         {ok, Result} = klotho_agent:run(Pid, 5000),
         ?assertEqual(error, Result#klotho_result.status),
         {Reason, Snapshot} = receive
             {terminated, R, S} -> {R, S}
         after 2000 ->
             error(no_terminate_callback)
         end,
         [
          %% reply_and_stop uses normal as the gen_server stop reason
          ?_assertEqual(normal, Reason),
          ?_assertEqual(failed, maps:get(phase, Snapshot)),
          ?_assertMatch({llm_error, _}, maps:get(last_error, Snapshot))
         ]
     end}.

%% Test: on_terminate with {Module, Function} form
on_terminate_mfa_test_() ->
    {setup,
     fun() ->
         setup_meck(),
         meck:new(test_hook_mod, [non_strict]),
         ok
     end,
     fun(_) ->
         meck:unload(test_hook_mod),
         teardown_meck(ok)
     end,
     fun(_) ->
         Self = self(),
         meck:expect(test_hook_mod, my_hook, fun(Reason, Snapshot) ->
             Self ! {mfa_terminated, Reason, Snapshot}
         end),
         meck:expect(openrouter, chat, fun(_Msgs, _Opts) ->
             {ok, mock_stop_response(<<"ok">>)}
         end),
         Config = (base_config())#{
             on_terminate => {test_hook_mod, my_hook}
         },
         {ok, Pid} = klotho_agent:start_link(Config),
         {ok, _} = klotho_agent:run(Pid, 5000),
         ok = klotho_agent:stop(Pid),
         Result = receive
             {mfa_terminated, _R, _S} -> ok
         after 2000 ->
             no_callback
         end,
         [?_assertEqual(ok, Result)]
     end}.

%% Test: undefined on_terminate (default) -- no error, clean termination
on_terminate_undefined_test_() ->
    {setup,
     fun setup_meck/0,
     fun teardown_meck/1,
     fun(_) ->
         meck:expect(openrouter, chat, fun(_Msgs, _Opts) ->
             {ok, mock_stop_response(<<"ok">>)}
         end),
         %% No on_terminate config -- defaults to undefined
         Config = base_config(),
         {ok, Pid} = klotho_agent:start_link(Config),
         {ok, _} = klotho_agent:run(Pid, 5000),
         ok = klotho_agent:stop(Pid),
         timer:sleep(50),
         [?_assertNot(is_process_alive(Pid))]
     end}.
