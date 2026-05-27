-module(klotho_mcp).
-include_lib("klotho/include/klotho.hrl").
-include_lib("erl_mcp/include/erl_mcp_client.hrl").
-export([tools_from_client/1, tools_from_client/2]).

-define(DEFAULT_TIMEOUT, 30000).

%% @doc Discover tools from an erl_mcp_client with default options.
-spec tools_from_client(ClientRef) ->
    {ok, [#klotho_tool{}]} | {error, term()}
  when ClientRef :: pid() | atom().
tools_from_client(ClientRef) ->
    tools_from_client(ClientRef, #{}).

%% @doc Discover tools from an erl_mcp_client and convert them to
%% klotho_tool records.
%%
%% When the second argument is an integer, it is treated as a
%% timeout (backward compatible). When it is a map, supported
%% options are:
%%
%%   `timeout' -- per-tool call timeout in ms (default 30000).
%%
%%   `filter' -- `fun(#mcp_client_tool{}) -> boolean()'. Called
%%     before conversion. Only tools for which the function
%%     returns `true' are included. Default: all tools.
%%
%%   `transform' -- `fun(#klotho_tool{}) -> #klotho_tool{}'.
%%     Called after conversion. Use to wrap handlers (metrics,
%%     logging), modify descriptions, or adjust schemas.
%%     Default: identity.
%%
%% Example:
%%
%%   klotho_mcp:tools_from_client(Pid, #{
%%       timeout => 60000,
%%       filter => fun(#mcp_client_tool{name = N}) ->
%%           N =:= <<"memory_read">>
%%       end
%%   }).
-spec tools_from_client(ClientRef, TimeoutOrOpts) ->
    {ok, [#klotho_tool{}]} | {error, term()}
  when ClientRef :: pid() | atom(),
       TimeoutOrOpts :: timeout() | map().
tools_from_client(ClientRef, Timeout) when is_integer(Timeout) ->
    tools_from_client(ClientRef, #{timeout => Timeout});
tools_from_client(ClientRef, Opts) when is_map(Opts) ->
    Timeout = maps:get(timeout, Opts, ?DEFAULT_TIMEOUT),
    Filter = maps:get(filter, Opts, fun(_) -> true end),
    Transform = maps:get(transform, Opts, fun(T) -> T end),
    case erl_mcp_client:list_tools(ClientRef) of
        {ok, McpTools} ->
            Filtered = [T || T <- McpTools, Filter(T)],
            Converted = [to_klotho_tool(T, ClientRef, Timeout)
                         || T <- Filtered],
            Transformed = [Transform(T) || T <- Converted],
            {ok, Transformed};
        {error, Reason} ->
            {error, Reason}
    end.

%% @private Convert one #mcp_client_tool{} to a #klotho_tool{}.
-spec to_klotho_tool(#mcp_client_tool{}, pid() | atom(), timeout()) ->
    #klotho_tool{}.
to_klotho_tool(#mcp_client_tool{name = Name,
                                 description = Desc,
                                 input_schema = Schema},
               ClientRef, Timeout) ->
    #klotho_tool{
        name = Name,
        description = ensure_binary(Desc),
        input_schema = Schema,
        handler = fun(Args) ->
            case erl_mcp_client:call(ClientRef, Name, Args, Timeout) of
                {ok, Result} ->
                    {ok, extract_content(Result)};
                {error, {tool_error, ErrResult}} ->
                    {error, extract_content(ErrResult)};
                {error, Reason} ->
                    {error, Reason}
            end
        end
    }.

%% @private Extract text content from MCP tools/call result.
%%
%% MCP results contain a `content' array of typed parts:
%%   [#{<<"type">> => <<"text">>, <<"text">> => <<"...">>}, ...]
%% We concatenate all text parts with newlines.
-spec extract_content(map()) -> binary().
extract_content(#{<<"content">> := Content}) when is_list(Content) ->
    Texts = [T || #{<<"type">> := <<"text">>, <<"text">> := T} <- Content],
    case Texts of
        [] -> <<"">>;
        _ -> iolist_to_binary(lists:join(<<"\n">>, Texts))
    end;
extract_content(#{<<"content">> := Content}) when is_binary(Content) ->
    Content;
extract_content(_) ->
    <<"">>.

-spec ensure_binary(binary() | undefined) -> binary().
ensure_binary(undefined) -> <<"">>;
ensure_binary(B) when is_binary(B) -> B.
