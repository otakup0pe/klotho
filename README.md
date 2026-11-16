# klotho

[![CI](https://github.com/otakup0pe/klotho/actions/workflows/ci.yml/badge.svg)](https://github.com/otakup0pe/klotho/actions/workflows/ci.yml)
[![Maintenance](https://img.shields.io/maintenance/yes/2026.svg)](https://github.com/otakup0pe/klotho)
[![Release](https://img.shields.io/github/v/release/otakup0pe/klotho)](https://github.com/otakup0pe/klotho/releases)
[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

An Erlang/OTP library for LLM agent tool-use loops. Named after the
Greek Fate who spins the thread of life.

This is a key component of `moirai` (the Fate who allots) the
reference harness that wires klotho together with
[erl_openrouter](https://github.com/otakup0pe/erl_openrouter) and
[erl_mcp](https://github.com/otakup0pe/erl_mcp).

## Requirements

- OTP 27+
- rebar3

## Quick Start

Add `klotho` to your `rebar.config` deps and to your application's
`applications` list, picking a version from
[releases](https://github.com/otakup0pe/klotho/releases).

### Run a single agent task

```erlang
-include_lib("klotho/include/klotho.hrl").

{ok, _} = application:ensure_all_started(klotho),

EchoTool = #klotho_tool{
    name = <<"echo">>,
    description = <<"Echoes input back">>,
    input_schema = #{<<"type">> => <<"object">>,
                     <<"properties">> => #{
                         <<"text">> => #{<<"type">> => <<"string">>}
                     }},
    handler = fun(Args) ->
        {ok, maps:get(<<"text">>, Args, <<>>)}
    end
},

Config = #{
    llm => #{model => <<"anthropic/claude-sonnet-4">>, temperature => 0.7},
    tools => [EchoTool],
    user_messages => [<<"Echo the word 'hello'">>],
    max_steps => 10
},

{ok, Pid} = klotho_agent:start_link(Config),
{ok, Result} = klotho_agent:run(Pid, 30000).
%% Result#klotho_result.message is the final assistant response.
%% Result#klotho_result.steps is the complete tool-use trace.
```

### Continue a bounded conversation

```erlang
Config = #{
    llm => #{model => <<"anthropic/claude-sonnet-4">>, temperature => 0.7},
    tools => [EchoTool],
    user_messages => [<<"What tools do you have?">>],
    max_steps => 10,
    max_turns => 15
},

{ok, Pid} = klotho_agent:start_link(Config),
{ok, R1} = klotho_agent:run(Pid, 30000),
{ok, R2} = klotho_agent:resume(Pid, <<"Now echo 'world'">>),
ok = klotho_agent:stop(Pid).
```

`resume/2` must be called by the process that called `run/2`.
Other processes receive `{error, foreign_caller}`. If the caller
dies, the agent terminates. A resume beyond `max_turns` returns:

```erlang
{error, {turn_limit_exhausted, #{
    turns_used => TurnsUsed,
    max_turns => MaxTurns,
    last_assistant_message => LastMessage,
    history => Messages
}}}
```

Set `max_turns => infinity` when the consumer owns the conversation
lifetime.

## What It Does

Klotho owns the LLM loop and optional tool dispatch:

1. Builds a conversation from system and user messages.
2. Sends it through `erl_openrouter`.
3. Runs requested tool handlers in parallel.
4. Returns tool results to the model until it finishes or a bound is hit.
5. Returns the final response and a complete step trace.
6. Accepts follow-up messages through `resume/2`.

It does not own memory, implement tools, run a persistent controller,
compact history, or abstract multiple LLM providers.

## Configuration

```erlang
#{
    llm               := #{
        model          := binary(),
        temperature    => number(),
        operation      => term(),
        opts           => map()
    },
    tools              => [#klotho_tool{}],          %% default []
    system_messages    => [binary()],                %% default []
    user_messages      := [binary()],
    max_steps          => pos_integer(),             %% default 15, per turn
    max_turns          => pos_integer() | infinity,  %% default 15
    max_wall_clock_ms  => pos_integer(),             %% default 120000, per turn
    tool_timeout_ms    => pos_integer(),             %% default 30000
    telemetry          => fun((term()) -> any())
                        | {Module, Function}
                        | undefined,
    pre_request        => fun(() -> proceed | {circuit_open, term()})
                        | undefined,
    on_terminate       => fun((Reason, AgentSnapshot) -> any())
                        | {Module, Function}
                        | undefined
}
```

Unknown keys in `llm.opts` pass through to `openrouter:chat/2`.
Top-level `model`, `temperature`, and `operation` values take
precedence over matching entries in `opts`.

### Tool deadlines

Each handler has its own `tool_timeout_ms` deadline. A timed-out
handler is killed, a structured error is returned to the model, and
the agent loop continues. Completed handlers cancel their timers.

### Request gate

`pre_request` runs immediately before every LLM request, including
requests made after tool results and on resumed turns. Return
`proceed` to send the request, or `{circuit_open, Reason}` to stop
before spending the request:

```erlang
Config = #{
    %% ...
    pre_request => fun() ->
        case my_breaker:allow_request() of
            true -> proceed;
            false -> {circuit_open, overloaded}
        end
    end
}.
```

A closed gate makes `run/2` or `resume/2` return
`{error, {circuit_open, Reason}}` and emits
`{circuit_open, Reason}`. If the callback raises, Klotho proceeds
with the request.

### Termination hook

`on_terminate` runs synchronously from `terminate/2` with the
gen_server termination reason and this flat snapshot:

```erlang
#{phase           => atom(),
  turn            => non_neg_integer(),
  step_count      => non_neg_integer(),
  messages        => [map()],
  steps           => [#klotho_step{}],
  result          => #klotho_result{} | undefined,
  elapsed_ms      => non_neg_integer(),
  last_error      => term() | undefined,
  max_turns       => pos_integer() | infinity,
  max_steps       => pos_integer(),
  tool_timeout_ms => pos_integer()}
```

Callback failures are logged without changing termination. Spawn
long-running cleanup from the callback rather than blocking it.

## Tools

```erlang
-record(klotho_tool, {
    name         :: binary(),
    description  :: binary(),
    input_schema :: map(),
    handler      :: fun((Args :: map()) -> {ok, iodata()} | {error, term()})
                  | {module(), atom()}
}).
```

`input_schema` uses the JSON Schema shape accepted by both MCP
`inputSchema` and OpenRouter `function.parameters`.

## Optional MCP Integration

The core agent loop does not start or call `erl_mcp`, so it is
runtime-optional. It remains a build dependency because `klotho_mcp`
compiles against the erl_mcp client record header. The adapter converts
tools discovered by an
[erl_mcp](https://github.com/otakup0pe/erl_mcp) client into
`#klotho_tool{}` records:

```erlang
{ok, Client} = erl_mcp_client:start_link(#{
    server_url => <<"https://gitmcp.io/owner/repo">>
}),
{ok, McpTools} = klotho_mcp:tools_from_client(Client, #{
    timeout => 30000
}),

Config = #{
    llm => #{model => <<"anthropic/claude-sonnet-4">>},
    tools => McpTools,
    user_messages => [<<"Summarize the README">>]
},
{ok, Pid} = klotho_agent:start_link(Config),
{ok, Result} = klotho_agent:run(Pid, 60000).
```

The adapter also accepts a timeout integer as its second argument.
The options map supports:

- `timeout`: timeout for each MCP tool call, in milliseconds.
- `filter`: predicate applied to each `#mcp_client_tool{}`.
- `transform`: function applied to each converted `#klotho_tool{}`.

The adapter holds no configuration or state. Each tool handler
captures the client reference and timeout, then delegates to
`erl_mcp_client:call/4`. Prefixed MCP tool names are preserved.

## Public API

```erlang
klotho_agent:start_link(Config)          -> {ok, Pid}
klotho_agent:child_spec(Config)          -> supervisor:child_spec()
klotho_agent:run(Pid, Timeout)           -> {ok, #klotho_result{}} | {error, Reason}
klotho_agent:resume(Pid, UserMessage)    -> {ok, #klotho_result{}} | {error, Reason}
klotho_agent:status(Pid)                 -> map()
klotho_agent:stop(Pid)                   -> ok

klotho_sup:start_agent(Config)           -> {ok, Pid} | {error, Reason}

klotho_mcp:tools_from_client(Client)      -> {ok, [#klotho_tool{}]} | {error, Reason}
klotho_mcp:tools_from_client(Client, OptsOrTimeout)
                                         -> {ok, [#klotho_tool{}]} | {error, Reason}
```

## Lifecycle

`klotho_agent` is a `gen_server` whose public status reports these
phases:

| Phase | Meaning |
|-------|---------|
| `idle` | Ready for `run/2` |
| `calling` | LLM request in flight |
| `dispatching` | Tool handlers running |
| `awaiting_resume` | Turn complete; ready for `resume/2` or `stop/1` |
| `failed` | A bound, gate, transport, or handler failure ended the loop |

## Telemetry Events

| Event | Meaning |
|-------|---------|
| `{turn_start, TurnNumber}` | Turn started |
| `{turn_end, TurnNumber}` | Turn completed |
| `{turn_limit_hit, TurnsUsed, MaxTurns}` | Resume exceeded the turn limit |
| `{tool_calls, StepNumber, TurnNumber, ToolCalls}` | Tool calls dispatched |
| `{step_complete, Step}` | Tool results collected |
| `{done, Result}` | Model returned `stop` |
| `{finished, FinishReason, Result}` | Model returned another finish reason |
| `{error, Reason}` | Agent failed |
| `{circuit_open, Reason}` | Request gate stopped an LLM call |
| `{tool_timeout, ToolCallId, TimeoutMs}` | Tool call exceeded its deadline |
| `{caller_died, Reason}` | Owning process died |
| `max_steps_exceeded` | Turn exceeded its step limit |

## Related Projects

- [erl_openrouter](https://github.com/otakup0pe/erl_openrouter) — LLM transport with tool use
- [erl_mcp](https://github.com/otakup0pe/erl_mcp) — optional MCP client adapter

## Testing

```console
make test
make local-test
make local-eunit
make dialyzer
```

## Note on AI Usage

This project has been developed with AI assistance. Contributions making use of AI generated content are welcome, however they _must_ be human reviewed prior to submission as pull requests, or issues. All contributors must be able to fully explain and defend any AI generated code, documentation, issues, or tests they submit. Contributions making use of AI must have this explicitly declared in the pull request or issue. This also applies to utilization of AI for reviewing of pull requests.

## Feedback

Open an issue at https://github.com/otakup0pe/klotho/issues.

## License

Apache-2.0. See [LICENSE](LICENSE).
