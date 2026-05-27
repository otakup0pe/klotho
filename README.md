# klotho

[![CI](https://github.com/otakup0pe/klotho/actions/workflows/ci.yml/badge.svg)](https://github.com/otakup0pe/klotho/actions/workflows/ci.yml)
[![Maintenance](https://img.shields.io/maintenance/yes/2026.svg)](https://github.com/otakup0pe/klotho)
[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

Erlang/OTP library for a LLM agent tool-use loop. Named after the
Greek Fate who spins the thread of life -- klotho spins the agent
loop.

Sibling project: [moirai](https://github.com/otakup0pe/moirai) (reference
harness wiring erl_openrouter + erl_mcp + klotho for end-to-end demos).

## Requirements

- OTP 27+
- rebar3

## Quick Start

	Add the dependency to `rebar.config`:

```erlang
{deps, [
    {klotho, {git, "https://github.com/otakup0pe/klotho.git", {tag, "0.1.0"}}}
]}.
```

Add `klotho` and `erl_openrouter` to your application's `applications`
list -- klotho dispatches LLM calls via `openrouter:chat/2`.

### Run a single agent task (one-shot)

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
%% Result#klotho_result.status =:= ok
%% Result#klotho_result.message contains the final assistant response
%% Result#klotho_result.steps contains the full tool-use trace
```

### Multi-turn conversation (bounded)

```erlang
Config = #{
    llm => #{model => <<"anthropic/claude-sonnet-4">>, temperature => 0.7},
    tools => [EchoTool],
    user_messages => [<<"What tools do you have?">>],
    max_steps => 10,
    max_turns => 15   %% default; set lower for tighter bounds, or infinity
},

{ok, Pid} = klotho_agent:start_link(Config),

%% Turn 1: initial run
{ok, R1} = klotho_agent:run(Pid, 30000),
%% R1#klotho_result.turn_number =:= 1

%% Turn 2: resume with a follow-up
{ok, R2} = klotho_agent:resume(Pid, <<"Now echo 'world'">>),
%% R2#klotho_result.turn_number =:= 2

%% Turn N: continue as needed...
%% When max_turns is reached, resume/2 returns:
%%   {error, {turn_limit_exhausted, #{turns_used, max_turns,
%%                                     last_assistant_message, history}}}

%% Stop when done
ok = klotho_agent:stop(Pid).
```

`resume/2` must be called from the same process that called `run/2`.
Calls from other processes return `{error, foreign_caller}`. The agent
monitors the caller -- if the caller dies, the agent terminates.

## What It Does

klotho is _just_ the llm loop, with optional tool use.

1. Accept a task (messages + tool list + constraints)
2. Process a LLM response through `erl_openrouter`
3. Receive `tool_calls` responses, dispatch them to registered handlers
4. Iterating on tool use until OpenRouter says "stop" or a bound is reached
5. Return a final result with the full step trace
6. Optionally accept follow-up user messages via `resume/2` for
   multi-turn conversations (bounded by `max_turns`)

## What It Does Not Do

- **Own memory or context** -- that is the consumer's concern
- **Speak MCP directly** -- consumers that need MCP tools wrap an
  `erl_mcp_client` pid in a klotho tool handler
- **Hold opinions about LLM providers** -- OpenRouter-first via
  `erl_openrouter`; for now that is the only supported path
- **Implement tools** -- handlers are caller-provided
- **Run as a daemon** -- workers are per-task; consumers compose
  with a controller process for persistence
- **Compact or summarize history** -- bounded multi-turn only

## MCP Integration

`klotho_mcp` bridges [erl_mcp](https://github.com/otakup0pe/erl_mcp)
clients into klotho agents. It converts remote MCP tools into
`#klotho_tool{}` records whose handlers delegate back to the MCP
client:

```erlang
{ok, Client} = erl_mcp_client:start_link(#{
    server_url => <<"https://gitmcp.io/owner/repo">>
}),
{ok, McpTools} = klotho_mcp:tools_from_client(Client, 30000),
%% McpTools are now #klotho_tool{} records, ready for klotho_agent

Config = #{
    llm => #{model => <<"anthropic/claude-sonnet-4">>},
    tools => McpTools,
    user_messages => [<<"Summarize the README">>],
    max_steps => 10
},
{ok, Pid} = klotho_agent:start_link(Config),
{ok, Result} = klotho_agent:run(Pid, 60000).
```

The bridge is intentionally thin -- no config, no state, no
supervision. Each `#klotho_tool{}` handler captures the client pid
and timeout in a closure and delegates to `erl_mcp_client:call/4`.
Tool names use the prefixed form from `#mcp_client_tool.name` so
`erl_mcp_client`'s `tool_prefix` option works naturally.

## Architecture

`klotho_agent` is a `gen_server` with an explicit `#state{phase}`
field tracking lifecycle:

| Phase | Description |
|-------|-------------|
| `idle` | Accepting the task spec, validating config |
| `calling` | LLM request in flight |
| `dispatching` | Tool calls received, handlers executing in parallel |
| `awaiting_resume` | Turn complete (finish_reason=stop); waiting for resume/2 or stop |
| `done` | Terminal (reserved for explicit stop) |
| `failed` | Max steps / wall clock / LLM error / handler crash |

### Config

```erlang
#{
    llm              := #{model => binary(), temperature => float()},
    tools            := [#klotho_tool{}],
    system_messages  => [binary()],
    user_messages    := [binary()],
    max_steps        => pos_integer(),       %% default 15 (per turn)
    max_turns        => pos_integer() | infinity,  %% default 15
    max_wall_clock_ms => pos_integer(),      %% default 120000 (per turn)
    tool_timeout_ms  => pos_integer(),       %% default 30000 (enforced)
    telemetry        => fun((term()) -> any()),
    on_terminate     => fun((Reason, AgentSnapshot) -> any())
                      | {Module, Function}
                      | undefined            %% default undefined
}
```

**`tool_timeout_ms`** -- Per-tool-call deadline. Each dispatched tool
handler gets a timer; if the handler does not return within the
deadline, the handler process is killed and a structured error message
(`"Tool call timed out after Xms"`) is sent to the LLM as the tool
result. The agent loop continues normally. Fast-completing handlers
cancel their timers automatically; no stale timeouts accumulate.

**`on_terminate`** -- Optional callback invoked synchronously during
`terminate/2`. Receives the gen_server termination reason and an
`AgentSnapshot` map:

```erlang
#{phase         => atom(),           %% idle | calling | ... | failed
  turn          => non_neg_integer(),
  step_count    => non_neg_integer(),
  messages      => [map()],          %% full conversation history
  steps         => [#klotho_step{}], %% tool-use trace
  result        => #klotho_result{} | undefined,
  elapsed_ms    => non_neg_integer(),
  last_error    => term() | undefined,
  max_turns     => pos_integer(),
  max_steps     => pos_integer(),
  tool_timeout_ms => pos_integer()}
```

The hook **must not crash terminate** -- if it raises, a warning is
logged via `logger:warning/2` and termination continues. Long-running
cleanup should spawn its own process and return immediately.

Example: produce an episodic digest on agent shutdown:

```erlang
Config = #{
    %% ... other config ...
    on_terminate => fun(Reason, #{messages := Msgs, turn := Turn,
                                  elapsed_ms := Elapsed} = _Snapshot) ->
        spawn(fun() ->
            my_app_digest:save(#{
                agent => <<"my-agent">>,
                reason => Reason,
                turns_used => Turn,
                elapsed_ms => Elapsed,
                messages => Msgs
            })
        end)
    end
}.
```

### Tool Spec

```erlang
-record(klotho_tool, {
    name         :: binary(),
    description  :: binary(),
    input_schema :: map(),      %% JSON Schema
    handler      :: fun((Args :: map()) -> {ok, iodata()} | {error, term()})
                  | {module(), atom()}
}).
```

`input_schema` is interchangeable with both MCP `inputSchema` and
OpenRouter `function.parameters`.

### Public API

```erlang
klotho_agent:start_link(Config)            -> {ok, Pid}
klotho_agent:child_spec(Config)            -> supervisor:child_spec()
klotho_agent:run(Pid, Timeout)             -> {ok, #klotho_result{}} | {error, Reason}
klotho_agent:resume(Pid, NewUserMessage)   -> {ok, #klotho_result{}} | {error, Reason}
klotho_agent:status(Pid)                   -> #{state, steps, turn, ...}
klotho_agent:stop(Pid)                     -> ok
```

### Telemetry Events

The telemetry callback receives these events:

| Event | Description |
|-------|-------------|
| `{turn_start, TurnNumber}` | New turn beginning |
| `{turn_end, TurnNumber}` | Turn completed successfully |
| `{turn_limit_hit, TurnsUsed, MaxTurns}` | Turn limit reached on resume attempt |
| `{tool_calls, StepNumber, TurnNumber, ToolCalls}` | Tool calls dispatched |
| `{step_complete, Step}` | Step finished (all tool results collected) |
| `{done, Result}` | Agent finished with stop |
| `{finished, FinishReason, Result}` | Agent finished with other reason |
| `{error, Reason}` | Agent error |
| `{tool_timeout, ToolCallId, TimeoutMs}` | Tool call exceeded its deadline |
| `{caller_died, Reason}` | Caller process died |
| `max_steps_exceeded` | Max steps bound hit |

## Reference Stack

- [erl_openrouter](https://github.com/otakup0pe/erl_openrouter) -- LLM transport with tool use
- [erl_mcp](https://github.com/otakup0pe/erl_mcp) -- MCP protocol client and server
- **klotho** (this repo) -- tool-use loop orchestrator
- [moirai](https://github.com/otakup0pe/moirai) -- end-to-end harness wiring all three

## Testing

```
make test          # Docker-based (recommended)
make local-test    # eunit + common_test directly
make local-eunit   # eunit only
make dialyzer      # dialyzer
```

## Note on AI Usage

This project has been developed with AI assistance. Contributions making
use of AI generated content are welcome, however they _must_ be human
reviewed prior to submission as pull requests, or issues. All contributors
must be able to fully explain and defend any AI generated code,
documentation, issues, or tests they submit. Contributions making use of
AI must have this explicitly declared in the pull request or issue. This
also applies to utilization of AI for reviewing of pull requests.

## Feedback

Open an issue at https://github.com/otakup0pe/klotho/issues

## License

Apache-2.0. See [LICENSE](LICENSE).
