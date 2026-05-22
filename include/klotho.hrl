-ifndef(KLOTHO_HRL).
-define(KLOTHO_HRL, true).

%% Default limits
-define(DEFAULT_MAX_STEPS, 15).
-define(DEFAULT_MAX_TURNS, 15).
-define(DEFAULT_MAX_WALL_CLOCK_MS, 120000).
-define(DEFAULT_TOOL_TIMEOUT_MS, 30000).

%% Tool definition -- the shape consumers provide to klotho.
%%
%% `input_schema' uses the same JSON Schema map shape as both
%% OpenRouter function.parameters and MCP inputSchema, so adapters
%% between tool sources and klotho are trivial.
-record(klotho_tool, {
    name         :: binary(),
    description  :: binary(),
    input_schema :: map(),        %% JSON Schema
    handler      :: fun((Args :: map()) -> {ok, iodata()} | {error, term()})
                  | {module(), atom()}
}).

-record(klotho_step, {
    step_number  :: pos_integer(),
    turn_number  :: pos_integer(),
    tool_calls   :: [map()],         %% raw tool_call maps from LLM
    tool_results :: [map()],         %% role=tool messages sent back
    duration_ms  :: non_neg_integer()
}).

-record(klotho_result, {
    status       :: ok | max_steps | timeout | error,
    message      :: binary() | undefined,   %% final assistant content
    steps        :: [#klotho_step{}],
    total_steps  :: non_neg_integer(),
    turn_number  :: pos_integer() | undefined,
    elapsed_ms   :: non_neg_integer(),
    error        :: term() | undefined
}).

-endif.
