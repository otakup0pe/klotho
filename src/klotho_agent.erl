-module(klotho_agent).
-behaviour(gen_server).

%% @doc The klotho agent loop --  one or more %% turns through
%% an LLM loop, with optional tool-use.
%%
%% Phases: idle -> calling -> dispatching -> awaiting_resume | done | failed
%%
%% The worker accepts a config map, monitors the caller, drives
%% LLM requests through erl_openrouter, dispatches tool calls to
%% registered handlers, and loops until finish_reason=stop or
%% a bound (max_steps / max_turns / wall_clock) is hit.
%%
%% After finish_reason=stop the agent enters `awaiting_resume'.
%% The original caller may feed a follow-up user message via
%% resume/2 to start another turn; the agent re-enters `calling'
%% with the augmented history.  When the turn limit is reached
%% the agent returns {error, {turn_limit_exhausted, Info}} and
%% terminates.

-include("klotho.hrl").
-include_lib("erl_openrouter/include/openrouter.hrl").

-export([start_link/1, child_spec/1, run/2, resume/2, status/1, stop/1]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2]).

-record(state, {
    phase = idle     :: idle | calling | dispatching
                      | awaiting_resume | done | failed,

    %% Config
    llm              :: map(),
    tools            :: [#klotho_tool{}],
    system_messages  :: [binary()],
    max_steps        :: pos_integer(),
    max_turns        :: pos_integer() | infinity,
    max_wall_clock_ms :: pos_integer(),
    tool_timeout_ms  :: pos_integer(),
    telemetry        :: fun((term()) -> any())
                      | {module(), atom()}
                      | undefined,
    on_terminate     :: fun((term(), map()) -> any())
                      | {module(), atom()}
                      | undefined,
    pre_request      :: fun(() -> proceed | {circuit_open, term()})
                      | undefined,

    %% Runtime
    messages         :: [map()],
    steps            :: [#klotho_step{}],
    step_count = 0   :: non_neg_integer(),
    turn_count = 0   :: non_neg_integer(),
    caller           :: gen_server:from() | undefined,
    caller_pid       :: pid() | undefined,
    caller_mon       :: reference() | undefined,
    start_time       :: integer() | undefined,
    step_start       :: integer() | undefined,
    last_result      :: #klotho_result{} | undefined,
    last_error       :: term() | undefined,

    %% Dispatching state
    pending_calls    :: [map()] | undefined,
    pending_results  :: [map()] | undefined,
    dispatch_refs    :: #{reference() => map()} | undefined,
    dispatch_pids    :: #{reference() => pid()} | undefined,
    tool_timers      :: #{reference() => reference()} | undefined
}).

%% @doc Start a klotho agent worker.
%%
%% Config keys:
%%   llm              := #{model => binary(),
%%                         temperature => float()} (required)
%%   tools            := [#klotho_tool{}]           (required)
%%   system_messages  => [binary()]                  (optional)
%%   user_messages    := [binary()]                  (required)
%%   max_steps        => pos_integer()               (default 15)
%%   max_turns        => pos_integer()               (default 15)
%%   max_wall_clock_ms => pos_integer()              (default 120000)
%%   tool_timeout_ms  => pos_integer()               (default 30000)
%%   telemetry        => fun((term()) -> any())      (optional)
%%   on_terminate     => fun((Reason, AgentSnapshot) -> any())
%%                     | {Module, Function}
%%                     | undefined                   (default undefined)
%%
%% The on_terminate hook fires synchronously during gen_server
%% terminate/2.  It receives the termination reason and a snapshot
%% map:
%%   #{phase, turn, step_count, messages, steps, result,
%%     elapsed_ms, last_error, max_turns, max_steps,
%%     tool_timeout_ms}
%% The hook MUST NOT crash terminate -- if it raises, a warning is
%% logged and termination continues.  Long-running cleanup should
%% spawn its own process and return immediately.
-spec start_link(map()) -> {ok, pid()} | {error, term()}.
start_link(Config) ->
    gen_server:start_link(?MODULE, Config, []).

-spec child_spec(map()) -> supervisor:child_spec().
child_spec(Config) ->
    #{id => ?MODULE,
      start => {?MODULE, start_link, [Config]},
      restart => temporary,
      shutdown => 5000,
      type => worker,
      modules => [?MODULE]}.

%% @doc Run the agent loop synchronously.
%%
%% Blocks until the loop completes or the timeout is reached.
%% Returns the final result with the full step trace.
-spec run(pid(), timeout()) -> {ok, #klotho_result{}} | {error, term()}.
run(Pid, Timeout) ->
    gen_server:call(Pid, run, Timeout).

%% @doc Resume the agent with a new user message.
%%
%% Only valid from the `awaiting_resume' phase, and only from the
%% same process that called run/2.  Returns {error, invalid_state}
%% if the agent is not awaiting resume, or {error, foreign_caller}
%% if called from a different process.
-spec resume(pid(), binary() | map()) -> {ok, #klotho_result{}} | {error, term()}.
resume(Pid, NewUserMessage) ->
    gen_server:call(Pid, {resume, NewUserMessage}, infinity).

-spec status(pid()) -> map().
status(Pid) ->
    gen_server:call(Pid, status, 5000).

-spec stop(pid()) -> ok.
stop(Pid) ->
    gen_server:stop(Pid).

init(Config) ->
    process_flag(trap_exit, true),
    case validate_config(Config) of
        {ok, State} ->
            {ok, State};
        {error, Reason} ->
            {stop, {bad_config, Reason}}
    end.

handle_call(run, From, #state{phase = idle} = State) ->
    {CallerPid, _} = From,
    MonRef = erlang:monitor(process, CallerPid),
    Now = erlang:monotonic_time(millisecond),
    TurnCount = 1,
    emit_telemetry(State, {turn_start, TurnCount}),
    NewState = State#state{
        caller = From,
        caller_pid = CallerPid,
        caller_mon = MonRef,
        start_time = Now,
        turn_count = TurnCount
    },
    enter_calling(NewState);

handle_call(run, _From, #state{phase = Phase} = _State) ->
    {reply, {error, {invalid_state, Phase}}, _State};

handle_call({resume, _Msg}, _From, #state{phase = failed} = State) ->
    {reply, {error, invalid_state}, State};

handle_call({resume, _Msg}, _From, #state{phase = done} = State) ->
    {reply, {error, invalid_state}, State};

handle_call({resume, NewUserMessage}, From, #state{phase = awaiting_resume} = State) ->
    {CallerPid, _} = From,
    case State#state.caller_pid of
        CallerPid ->
            NextTurn = State#state.turn_count + 1,
            case NextTurn > State#state.max_turns of
                true ->
                    emit_telemetry(State, {turn_limit_hit, State#state.turn_count,
                                           State#state.max_turns}),
                    LastMsg = find_last_assistant_message(State#state.messages),
                    Info = #{turns_used => State#state.turn_count,
                             max_turns => State#state.max_turns,
                             last_assistant_message => LastMsg,
                             history => State#state.messages},
                    {stop, normal, {error, {turn_limit_exhausted, Info}}, State};
                false ->
                    UserMsg = normalize_user_message(NewUserMessage),
                    NewMessages = State#state.messages ++ [UserMsg],
                    emit_telemetry(State, {turn_start, NextTurn}),
                    NewState = State#state{
                        caller = From,
                        messages = NewMessages,
                        steps = [],
                        step_count = 0,
                        turn_count = NextTurn,
                        start_time = erlang:monotonic_time(millisecond)
                    },
                    enter_calling(NewState)
            end;
        _ ->
            {reply, {error, foreign_caller}, State}
    end;

handle_call({resume, _Msg}, _From, #state{phase = Phase} = State) ->
    {reply, {error, {invalid_state, Phase}}, State};

handle_call(status, _From, #state{phase = dispatching, dispatch_refs = Refs} = State) ->
    Remaining = maps:size(Refs),
    {reply, #{state => dispatching,
              steps => State#state.step_count,
              turn => State#state.turn_count,
              pending_tools => Remaining}, State};

handle_call(status, _From, #state{phase = Phase} = State) ->
    {reply, #{state => Phase,
              steps => State#state.step_count,
              turn => State#state.turn_count}, State};

handle_call(_Msg, _From, State) ->
    {reply, {error, invalid_request}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({llm_result, {ok, Response}}, #state{phase = calling} = State) ->
    handle_llm_response(Response, State);

handle_info({llm_result, {error, Reason}}, #state{phase = calling} = State) ->
    finish_with_error({llm_error, Reason}, State);

handle_info({'EXIT', _Pid, normal}, #state{phase = calling} = State) ->
    {noreply, State};

handle_info({'EXIT', _Pid, Reason}, #state{phase = calling} = State) ->
    finish_with_error({llm_worker_crashed, Reason}, State);

handle_info({tool_result, Ref, ToolCallId, Result}, #state{phase = dispatching} = State) ->
    handle_tool_result(Ref, ToolCallId, Result, State);

handle_info({tool_timeout, Ref, ToolCallId, ToolPid}, #state{phase = dispatching} = State) ->
    case maps:is_key(Ref, State#state.dispatch_refs) of
        true ->
            case is_process_alive(ToolPid) of
                true -> exit(ToolPid, tool_timeout);
                false -> ok
            end,
            TimeoutMs = State#state.tool_timeout_ms,
            emit_telemetry(State, {tool_timeout, ToolCallId, TimeoutMs}),
            ErrorMsg = iolist_to_binary(io_lib:format(
                "Tool call timed out after ~bms", [TimeoutMs])),
            handle_tool_result(Ref, ToolCallId, {error, {tool_timeout, ErrorMsg}}, State);
        false ->
            {noreply, State}
    end;

handle_info({'DOWN', MonRef, process, _Pid, Reason}, #state{phase = dispatching,
                                                             caller_mon = CallerMon} = State)
  when MonRef =/= CallerMon ->
    handle_tool_crash(MonRef, Reason, State);

handle_info({'DOWN', MonRef, process, _Pid, Reason}, #state{caller_mon = MonRef} = State) ->
    emit_telemetry(State, {caller_died, Reason}),
    {stop, {shutdown, caller_died}, State};

handle_info({tool_timeout, _Ref, _ToolCallId, _ToolPid}, State) ->
    {noreply, State};

handle_info({'EXIT', _Pid, normal}, State) ->
    {noreply, State};

handle_info(_Msg, State) ->
    {noreply, State}.

terminate(Reason, #state{caller_mon = MonRef} = State) ->
    case is_reference(MonRef) of
        true -> erlang:demonitor(MonRef, [flush]);
        false -> ok
    end,
    invoke_on_terminate(Reason, State),
    ok.

enter_calling(State) ->
    Self = self(),
    Messages = State#state.messages,
    LLM = State#state.llm,
    Tools = State#state.tools,
    case check_pre_request(State) of
        proceed ->
            StepStart = erlang:monotonic_time(millisecond),
            spawn_link(fun() ->
                Result = call_llm(LLM, Messages, Tools),
                Self ! {llm_result, Result}
            end),
            {noreply, State#state{phase = calling, step_start = StepStart}};
        {circuit_open, Reason} ->
            emit_telemetry(State, {circuit_open, Reason}),
            Result = #klotho_result{
                status = error,
                error = {circuit_open, Reason},
                steps = State#state.steps,
                total_steps = State#state.step_count,
                turn_number = State#state.turn_count,
                elapsed_ms = elapsed_ms(State)
            },
            gen_server:reply(State#state.caller, {error, {circuit_open, Reason}}),
            {noreply, State#state{phase = failed, last_result = Result,
                                  caller = undefined}}
    end.

enter_dispatching(State) ->
    PendingCalls = State#state.pending_calls,
    Tools = State#state.tools,
    ToolTimeout = State#state.tool_timeout_ms,
    {DispatchRefs, DispatchPids, ToolTimers} =
        dispatch_tool_calls(PendingCalls, Tools, ToolTimeout),
    {noreply, State#state{
        phase = dispatching,
        dispatch_refs = DispatchRefs,
        dispatch_pids = DispatchPids,
        tool_timers = ToolTimers,
        pending_results = []
    }}.

validate_config(Config) when is_map(Config) ->
    try
        LLM = maps:get(llm, Config),
        Tools = maps:get(tools, Config, []),
        UserMessages = maps:get(user_messages, Config),
        SystemMessages = maps:get(system_messages, Config, []),
        MaxSteps = maps:get(max_steps, Config, ?DEFAULT_MAX_STEPS),
        MaxTurns = maps:get(max_turns, Config, ?DEFAULT_MAX_TURNS),
        MaxWallClock = maps:get(max_wall_clock_ms, Config, ?DEFAULT_MAX_WALL_CLOCK_MS),
        ToolTimeout = maps:get(tool_timeout_ms, Config, ?DEFAULT_TOOL_TIMEOUT_MS),
        Telemetry = maps:get(telemetry, Config, undefined),
        OnTerminate = maps:get(on_terminate, Config, undefined),
        PreRequest = maps:get(pre_request, Config, undefined),

        true = is_map(LLM),
        true = is_list(Tools),
        true = is_list(UserMessages),
        true = length(UserMessages) > 0,
        true = is_integer(MaxSteps) andalso MaxSteps > 0,
        true = (is_integer(MaxTurns) andalso MaxTurns > 0)
              orelse MaxTurns =:= infinity,
        true = is_integer(MaxWallClock) andalso MaxWallClock > 0,

        SysMsgs = [#{<<"role">> => <<"system">>, <<"content">> => M}
                   || M <- SystemMessages],
        UserMsgs = [#{<<"role">> => <<"user">>, <<"content">> => M}
                    || M <- UserMessages],
        Messages = SysMsgs ++ UserMsgs,

        {ok, #state{
            llm = LLM,
            tools = Tools,
            system_messages = SystemMessages,
            max_steps = MaxSteps,
            max_turns = MaxTurns,
            max_wall_clock_ms = MaxWallClock,
            tool_timeout_ms = ToolTimeout,
            telemetry = Telemetry,
            on_terminate = OnTerminate,
            pre_request = PreRequest,
            messages = Messages,
            steps = [],
            step_count = 0,
            turn_count = 0
        }}
    catch
        error:{badkey, Key} ->
            {error, {missing_required_key, Key}};
        error:{badmatch, _} ->
            {error, invalid_config}
    end;
validate_config(_) ->
    {error, not_a_map}.

call_llm(LLM, Messages, Tools) ->
    Model = maps:get(model, LLM),
    Temperature = maps:get(temperature, LLM, 0.7),
    ExtraOpts = maps:get(opts, LLM, #{}),

    Opts0 = maps:merge(ExtraOpts, #{model => Model, temperature => Temperature}),
    Opts1 = case maps:find(operation, LLM) of
        {ok, Op} -> Opts0#{operation => Op};
        error -> Opts0
    end,
    Opts = case Tools of
        [] -> Opts1;
        _ ->
            EncodedTools = encode_tools(Tools),
            Opts1#{tools => EncodedTools}
    end,

    openrouter:chat(Messages, Opts).

encode_tools(Tools) ->
    [encode_tool(T) || T <- Tools].

encode_tool(#klotho_tool{name = Name, description = Desc, input_schema = Schema}) ->
    #tool{
        type = <<"function">>,
        function = #tool_function{
            name = Name,
            description = Desc,
            parameters = Schema
        }
    }.

handle_llm_response(#chat_response{choices = Choices}, State) ->
    case Choices of
        [Choice | _] ->
            Message = maps:get(<<"message">>, Choice, #{}),
            FinishReason = maps:get(<<"finish_reason">>, Choice, undefined),
            handle_choice(Message, FinishReason, State);
        [] ->
            finish_with_error({llm_error, empty_choices}, State)
    end;
handle_llm_response(Other, State) ->
    finish_with_error({llm_error, {unexpected_response, Other}}, State).

handle_choice(Message, FinishReason, State)
  when FinishReason =:= <<"stop">>; FinishReason =:= stop ->
    Content = maps:get(<<"content">>, Message, <<>>),
    Elapsed = elapsed_ms(State),
    TurnNumber = State#state.turn_count,
    Result = #klotho_result{
        status = ok,
        message = Content,
        steps = lists:reverse(State#state.steps),
        total_steps = State#state.step_count,
        turn_number = TurnNumber,
        elapsed_ms = Elapsed
    },
    emit_telemetry(State, {turn_end, TurnNumber}),
    emit_telemetry(State, {done, Result}),
    AssistantMsg = #{<<"role">> => <<"assistant">>, <<"content">> => Content},
    NewMessages = State#state.messages ++ [AssistantMsg],
    NewState = State#state{
        phase = awaiting_resume,
        messages = NewMessages,
        last_result = Result
    },
    gen_server:reply(State#state.caller, {ok, Result}),
    {noreply, NewState#state{caller = undefined}};

handle_choice(Message, FinishReason, State)
  when FinishReason =:= <<"tool_calls">>; FinishReason =:= tool_calls ->
    ToolCalls = maps:get(<<"tool_calls">>, Message, []),
    case ToolCalls of
        [] ->
            finish_with_error({llm_error, tool_calls_empty}, State);
        _ ->
            NewStepCount = State#state.step_count + 1,
            case NewStepCount > State#state.max_steps of
                true ->
                    finish_with_max_steps(State);
                false ->
                    case check_wall_clock(State) of
                        ok ->
                            AssistantMsg = #{<<"role">> => <<"assistant">>,
                                            <<"content">> => null,
                                            <<"tool_calls">> => ToolCalls},
                            NewMessages = State#state.messages ++ [AssistantMsg],
                            TurnNumber = State#state.turn_count,
                            emit_telemetry(State, {tool_calls, NewStepCount,
                                                   TurnNumber, ToolCalls}),
                            NewState = State#state{
                                messages = NewMessages,
                                step_count = NewStepCount,
                                pending_calls = ToolCalls
                            },
                            enter_dispatching(NewState);
                        timeout ->
                            finish_with_error(wall_clock_timeout, State)
                    end
            end
    end;

handle_choice(Message, FinishReason, State) ->
    %% Other finish reasons (length, content_filter, etc.)
    Content = maps:get(<<"content">>, Message, <<>>),
    Elapsed = elapsed_ms(State),
    TurnNumber = State#state.turn_count,
    Result = #klotho_result{
        status = ok,
        message = Content,
        steps = lists:reverse(State#state.steps),
        total_steps = State#state.step_count,
        turn_number = TurnNumber,
        elapsed_ms = Elapsed
    },
    emit_telemetry(State, {turn_end, TurnNumber}),
    emit_telemetry(State, {finished, FinishReason, Result}),
    AssistantMsg = #{<<"role">> => <<"assistant">>, <<"content">> => Content},
    NewMessages = State#state.messages ++ [AssistantMsg],
    NewState = State#state{
        phase = awaiting_resume,
        messages = NewMessages,
        last_result = Result
    },
    gen_server:reply(State#state.caller, {ok, Result}),
    {noreply, NewState#state{caller = undefined}}.

dispatch_tool_calls(ToolCalls, Tools, ToolTimeout) ->
    Self = self(),
    ToolMap = build_tool_map(Tools),
    {RefTcPairs, PidMap, TimerMap} = lists:foldl(fun(TC, {Pairs, Pids, Timers}) ->
        FunMap = maps:get(<<"function">>, TC, #{}),
        ToolName = maps:get(<<"name">>, FunMap, <<>>),
        ToolCallId = maps:get(<<"id">>, TC, <<>>),
        ArgsRaw = maps:get(<<"arguments">>, FunMap, <<"{}">>),
        Args = decode_arguments(ArgsRaw),

        Ref = make_ref(),
        {Pid, MonRef} = spawn_monitor(fun() ->
            Result = execute_tool(ToolMap, ToolName, Args),
            Self ! {tool_result, Ref, ToolCallId, Result}
        end),
        put({dispatch_mon, MonRef}, {Ref, ToolCallId}),
        TimerRef = erlang:send_after(ToolTimeout, Self,
                                     {tool_timeout, Ref, ToolCallId, Pid}),
        {[{Ref, TC} | Pairs],
         Pids#{Ref => Pid},
         Timers#{Ref => TimerRef}}
    end, {[], #{}, #{}}, ToolCalls),
    {maps:from_list(RefTcPairs), PidMap, TimerMap}.

build_tool_map(Tools) ->
    maps:from_list([{T#klotho_tool.name, T} || T <- Tools]).

execute_tool(ToolMap, ToolName, Args) ->
    case maps:get(ToolName, ToolMap, undefined) of
        undefined ->
            {error, {unknown_tool, ToolName}};
        #klotho_tool{handler = Handler} ->
            try
                call_handler(Handler, Args)
            catch
                Class:Reason:Stack ->
                    {error, {handler_crashed, Class, Reason, Stack}}
            end
    end.

call_handler(Fun, Args) when is_function(Fun, 1) ->
    Fun(Args);
call_handler({Mod, Fun}, Args) ->
    Mod:Fun(Args).

decode_arguments(Bin) when is_binary(Bin) ->
    try json:decode(Bin) of
        Map when is_map(Map) -> Map;
        _ -> #{}
    catch
        _:_ -> #{}
    end;
decode_arguments(Map) when is_map(Map) ->
    Map;
decode_arguments(_) ->
    #{}.

handle_tool_result(Ref, ToolCallId, Result, State) ->
    case maps:take(Ref, State#state.dispatch_refs) of
        {_TC, RemainingRefs} ->
            NewTimers = cancel_tool_timer(Ref, State#state.tool_timers),
            NewPids = maps:remove(Ref, State#state.dispatch_pids),
            Content = format_tool_result(Result),
            ToolMsg = #{<<"role">> => <<"tool">>,
                        <<"tool_call_id">> => ToolCallId,
                        <<"content">> => Content},
            NewResults = [ToolMsg | State#state.pending_results],
            case maps:size(RemainingRefs) of
                0 ->
                    StepDuration = erlang:monotonic_time(millisecond) -
                                   State#state.step_start,
                    Step = #klotho_step{
                        step_number = State#state.step_count,
                        turn_number = State#state.turn_count,
                        tool_calls = State#state.pending_calls,
                        tool_results = lists:reverse(NewResults),
                        duration_ms = StepDuration
                    },
                    NewMessages = State#state.messages ++ lists:reverse(NewResults),
                    NewState = State#state{
                        messages = NewMessages,
                        steps = [Step | State#state.steps],
                        dispatch_refs = #{},
                        dispatch_pids = #{},
                        tool_timers = #{},
                        pending_calls = undefined,
                        pending_results = undefined
                    },
                    emit_telemetry(NewState, {step_complete, Step}),
                    enter_calling(NewState);
                _ ->
                    {noreply, State#state{
                        dispatch_refs = RemainingRefs,
                        dispatch_pids = NewPids,
                        tool_timers = NewTimers,
                        pending_results = NewResults
                    }}
            end;
        error ->
            {noreply, State}
    end.

handle_tool_crash(MonRef, Reason, State) ->
    case get({dispatch_mon, MonRef}) of
        {Ref, ToolCallId} ->
            erase({dispatch_mon, MonRef}),
            handle_tool_result(Ref, ToolCallId,
                              {error, {handler_crashed, Reason}}, State);
        undefined ->
            {noreply, State}
    end.

cancel_tool_timer(Ref, Timers) ->
    case maps:take(Ref, Timers) of
        {TimerRef, RemainingTimers} ->
            _ = erlang:cancel_timer(TimerRef, [{async, true}, {info, false}]),
            RemainingTimers;
        error ->
            Timers
    end.

format_tool_result({ok, Content}) when is_binary(Content) ->
    Content;
format_tool_result({ok, Content}) when is_list(Content) ->
    iolist_to_binary(Content);
format_tool_result({error, Reason}) ->
    iolist_to_binary(io_lib:format("ERROR: ~p", [Reason])).

finish_with_error(Reason, State) ->
    Elapsed = elapsed_ms(State),
    TurnNumber = State#state.turn_count,
    Result = #klotho_result{
        status = error,
        message = undefined,
        steps = lists:reverse(State#state.steps),
        total_steps = State#state.step_count,
        turn_number = TurnNumber,
        elapsed_ms = Elapsed,
        error = Reason
    },
    emit_telemetry(State, {error, Reason}),
    reply_and_stop(Result, State#state{last_result = Result,
                                       last_error = Reason}).

finish_with_max_steps(State) ->
    Elapsed = elapsed_ms(State),
    TurnNumber = State#state.turn_count,
    Result = #klotho_result{
        status = max_steps,
        message = undefined,
        steps = lists:reverse(State#state.steps),
        total_steps = State#state.step_count,
        turn_number = TurnNumber,
        elapsed_ms = Elapsed
    },
    emit_telemetry(State, max_steps_exceeded),
    reply_and_stop(Result, State#state{last_result = Result}).

reply_and_stop(Result, State) ->
    case State#state.caller of
        undefined ->
            {stop, normal, State#state{phase = failed}};
        Caller ->
            gen_server:reply(Caller, {ok, Result}),
            {stop, normal, State#state{caller = undefined, phase = failed}}
    end.

normalize_user_message(Msg) when is_binary(Msg) ->
    #{<<"role">> => <<"user">>, <<"content">> => Msg};
normalize_user_message(#{<<"role">> := <<"user">>} = Msg) ->
    Msg;
normalize_user_message(#{role := user, content := Content}) ->
    #{<<"role">> => <<"user">>, <<"content">> => Content}.

find_last_assistant_message(Messages) ->
    find_last_assistant_message(Messages, undefined).

find_last_assistant_message([], Acc) ->
    Acc;
find_last_assistant_message([#{<<"role">> := <<"assistant">>,
                               <<"content">> := Content} | Rest], _Acc)
  when Content =/= null ->
    find_last_assistant_message(Rest, Content);
find_last_assistant_message([_ | Rest], Acc) ->
    find_last_assistant_message(Rest, Acc).

elapsed_ms(#state{start_time = undefined}) -> 0;
elapsed_ms(#state{start_time = Start}) ->
    erlang:monotonic_time(millisecond) - Start.

check_wall_clock(#state{start_time = undefined}) -> ok;
check_wall_clock(#state{start_time = Start, max_wall_clock_ms = Max}) ->
    case erlang:monotonic_time(millisecond) - Start > Max of
        true -> timeout;
        false -> ok
    end.

check_pre_request(#state{pre_request = undefined}) ->
    proceed;
check_pre_request(#state{pre_request = Fun}) when is_function(Fun, 0) ->
    try Fun() of
        proceed -> proceed;
        {circuit_open, _} = Open -> Open
    catch _:_ -> proceed
    end.

emit_telemetry(#state{telemetry = undefined}, _Event) ->
    ok;
emit_telemetry(#state{telemetry = Fun}, Event) when is_function(Fun, 1) ->
    try Fun(Event) catch _:_ -> ok end;
emit_telemetry(#state{telemetry = {Mod, FunName}}, Event) ->
    try Mod:FunName(Event) catch _:_ -> ok end.

%% @doc Build a snapshot map of agent state for the on_terminate hook.
%%
%% Shape:
%%   #{phase         => atom(),
%%     turn          => non_neg_integer(),
%%     step_count    => non_neg_integer(),
%%     messages      => [map()],
%%     steps         => [#klotho_step{}],
%%     result        => #klotho_result{} | undefined,
%%     elapsed_ms    => non_neg_integer(),
%%     last_error    => term() | undefined,
%%     max_turns     => pos_integer(),
%%     max_steps     => pos_integer(),
%%     tool_timeout_ms => pos_integer()}
%%
%% The map shape is intentionally flat for forward compatibility.
%% Consumers should treat unrecognized keys as additive; pattern-
%% matching on the full shape will break on future additions.
build_agent_snapshot(State) ->
    #{phase         => State#state.phase,
      turn          => State#state.turn_count,
      step_count    => State#state.step_count,
      messages      => State#state.messages,
      steps         => lists:reverse(State#state.steps),
      result        => State#state.last_result,
      elapsed_ms    => elapsed_ms(State),
      last_error    => State#state.last_error,
      max_turns     => State#state.max_turns,
      max_steps     => State#state.max_steps,
      tool_timeout_ms => State#state.tool_timeout_ms}.

invoke_on_terminate(_Reason, #state{on_terminate = undefined}) ->
    ok;
invoke_on_terminate(Reason, #state{on_terminate = Hook} = State) ->
    Snapshot = build_agent_snapshot(State),
    try
        call_on_terminate(Hook, Reason, Snapshot)
    catch
        Class:Error:Stack ->
            logger:warning("on_terminate hook crashed: ~p:~p~n~p",
                           [Class, Error, Stack]),
            ok
    end.

call_on_terminate(Fun, Reason, Snapshot) when is_function(Fun, 2) ->
    Fun(Reason, Snapshot);
call_on_terminate({Mod, FunName}, Reason, Snapshot) ->
    Mod:FunName(Reason, Snapshot).
