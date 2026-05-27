# AGENTS.md

## Project

klotho is an Erlang/OTP library for the LLM agent tool-use loop.  It
drives single or multi-turn conversations through an openrouter
provided LLM with tool calls, dispatching to caller-provided handlers,
and returning results with full step traces. Requires OTP 27+ and
erl_openrouter for LLM transport.

## Build and Test

Tests must always be invoked via `make test`. Code quality may be
assesed via `make dialyzer`.

## Public API

| Module | Description |
|--------|-------------|
| `klotho_agent` | gen_server agent loop: start_link/1, run/2, resume/2, status/1, stop/1 |
| `klotho_mcp` | MCP bridge -- converts erl_mcp_client tools to #klotho_tool{} records for use in klotho agents |
| `klotho_sup` | simple_one_for_one supervisor for dynamic agent workers |

## OTP Infrastructure

| Module | Description |
|--------|-------------|
| `klotho_app` | OTP application callback, starts `klotho_sup` |
| `klotho_sup` | Top-level supervisor (simple_one_for_one for agent workers) |

## Include Files

- `include/klotho.hrl` -- Record definitions (#klotho_tool{}, #klotho_step{}, #klotho_result{}), default constants

## Test Layout (test/)

EUnit modules (suffix `_tests`):
- `klotho_agent_tests` -- agent loop tests (mocked LLM via meck), covers one-shot and multi-turn paths
- `klotho_mcp_tests` -- MCP bridge tests (mocked erl_mcp_client via meck), covers tool conversion, content extraction, error propagation

## Key Design Decisions

1. **gen_server with explicit phase field** -- The agent loop tracks
   lifecycle via `#state{phase = idle | calling | dispatching |
   awaiting_resume | done | failed}`. Phase 1 used gen_statem; Phase 2
   pivoted to gen_server because the resume/2 cycle through states
   made gen_statem's strict-state benefit no longer worth the audit
   cost when adding new states.

2. **Caller monitoring and identity** -- The worker monitors the
   caller pid. If the caller dies, the worker stops (no orphaned LLM
   calls burning money). `resume/2` is restricted to the same process
   that called `run/2` -- foreign callers get `{error, foreign_caller}`.

3. **Parallel tool dispatch** -- Tool calls are dispatched via
   spawn_monitor. Results are collected; crashes are caught and
   surfaced as tool error messages to the LLM.

4. **Multi-turn** -- `max_turns` (default 15, `infinity` allowed)
   caps how many user-turn cycles an agent will accept.
   Exceeding the limit returns `{error, {turn_limit_exhausted, Info}}`
   with the full conversation history for consumer-side handling.
   `infinity` disables the turn limit for consumer-driven sessions.

5. **OpenRouter-first, no provider behaviour yet** -- A TODO marks the
   provider abstraction seam. The behaviour emerges when a second
   provider exists.

6. **Tool shape is interchangeable** -- `#klotho_tool.input_schema`
   uses the same JSON Schema map as MCP inputSchema and OpenRouter
   function.parameters.

7. **No global state** -- Tool registry is caller-supplied config.
   No ETS tables, no registered processes beyond the supervisor.

8. **Tool timeout enforcement** -- `tool_timeout_ms` (default 30s) is
   enforced per dispatched tool call via `erlang:send_after`. Slow
   handlers are killed and a structured error message is returned to
   the LLM. Timers are cancelled on successful completion.

9. **on_terminate callback** -- Optional hook invoked synchronously in
   `terminate/2` with `(Reason, AgentSnapshot)`. Crash-safe via
   try/catch. Snapshot is a flat map with: `phase`, `turn`,
   `step_count`, `messages`, `steps`, `result`, `elapsed_ms`,
   `last_error`, `max_turns`, `max_steps`, `tool_timeout_ms`.

## Dependencies

- `erl_openrouter` (git) -- LLM transport with tool-use support
- `erl_mcp` (git) -- Optional MCP http/beam-local implementation

## Conventions

- `warnings_as_errors` is enabled in rebar.config
- No catch-all clauses that silently swallow errors
- Prefer returning `{error, Reason}` tuples over throwing
- Tests use meck for mocking. Do not mock third party libraries.
- Binary strings for all protocol-level data (tool names, etc.)
