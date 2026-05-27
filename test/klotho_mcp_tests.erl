-module(klotho_mcp_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("klotho/include/klotho.hrl").
-include_lib("erl_mcp/include/erl_mcp_client.hrl").

tools_from_client_test_() ->
    {foreach,
     fun setup/0,
     fun cleanup/1,
     [
      {"converts MCP tools to klotho tools", fun converts_tools/0},
      {"propagates list_tools error", fun propagates_list_error/0},
      {"handler delegates to client call", fun handler_delegates/0},
      {"handler extracts text content", fun handler_extracts_content/0},
      {"handler propagates tool error", fun handler_propagates_tool_error/0},
      {"handler propagates transport error", fun handler_propagates_transport_error/0},
      {"handles empty tool list", fun handles_empty_list/0},
      {"handles undefined description", fun handles_undefined_desc/0},
      {"handles multi-part content", fun handles_multi_part_content/0}
     ]}.

setup() ->
    meck:new(erl_mcp_client, [non_strict]),
    ok.

cleanup(_) ->
    meck:unload(erl_mcp_client).

converts_tools() ->
    Tool = #mcp_client_tool{
        name = <<"fetch_moirai_documentation">>,
        raw_name = <<"fetch_documentation">>,
        description = <<"Fetch docs">>,
        input_schema = #{<<"type">> => <<"object">>}
    },
    meck:expect(erl_mcp_client, list_tools, fun(_) -> {ok, [Tool]} end),
    {ok, [KT]} = klotho_mcp:tools_from_client(self(), 30000),
    ?assertEqual(<<"fetch_moirai_documentation">>, KT#klotho_tool.name),
    ?assertEqual(<<"Fetch docs">>, KT#klotho_tool.description),
    ?assertEqual(#{<<"type">> => <<"object">>}, KT#klotho_tool.input_schema),
    ?assert(is_function(KT#klotho_tool.handler, 1)).

propagates_list_error() ->
    meck:expect(erl_mcp_client, list_tools, fun(_) -> {error, not_ready} end),
    ?assertEqual({error, not_ready}, klotho_mcp:tools_from_client(self(), 30000)).

handler_delegates() ->
    Tool = #mcp_client_tool{
        name = <<"search_code">>,
        raw_name = <<"search_code">>,
        description = <<"Search">>,
        input_schema = #{<<"type">> => <<"object">>}
    },
    meck:expect(erl_mcp_client, list_tools, fun(_) -> {ok, [Tool]} end),
    meck:expect(erl_mcp_client, call, fun(_, <<"search_code">>, #{<<"q">> := <<"test">>}, 5000) ->
        {ok, #{<<"content">> => [#{<<"type">> => <<"text">>, <<"text">> => <<"result">>}]}}
    end),
    {ok, [KT]} = klotho_mcp:tools_from_client(self(), 5000),
    {ok, Result} = (KT#klotho_tool.handler)(#{<<"q">> => <<"test">>}),
    ?assertEqual(<<"result">>, Result).

handler_extracts_content() ->
    Tool = #mcp_client_tool{
        name = <<"t">>,
        raw_name = <<"t">>,
        description = <<"T">>,
        input_schema = #{}
    },
    meck:expect(erl_mcp_client, list_tools, fun(_) -> {ok, [Tool]} end),
    meck:expect(erl_mcp_client, call, fun(_, _, _, _) ->
        {ok, #{<<"content">> => [
            #{<<"type">> => <<"text">>, <<"text">> => <<"line1">>},
            #{<<"type">> => <<"text">>, <<"text">> => <<"line2">>}
        ]}}
    end),
    {ok, [KT]} = klotho_mcp:tools_from_client(self(), 5000),
    {ok, Result} = (KT#klotho_tool.handler)(#{}),
    ?assertEqual(<<"line1\nline2">>, Result).

handler_propagates_tool_error() ->
    Tool = #mcp_client_tool{
        name = <<"t">>,
        raw_name = <<"t">>,
        description = <<"T">>,
        input_schema = #{}
    },
    meck:expect(erl_mcp_client, list_tools, fun(_) -> {ok, [Tool]} end),
    meck:expect(erl_mcp_client, call, fun(_, _, _, _) ->
        {error, {tool_error, #{<<"content">> => [
            #{<<"type">> => <<"text">>, <<"text">> => <<"oops">>}
        ]}}}
    end),
    {ok, [KT]} = klotho_mcp:tools_from_client(self(), 5000),
    {error, <<"oops">>} = (KT#klotho_tool.handler)(#{}).

handler_propagates_transport_error() ->
    Tool = #mcp_client_tool{
        name = <<"t">>,
        raw_name = <<"t">>,
        description = <<"T">>,
        input_schema = #{}
    },
    meck:expect(erl_mcp_client, list_tools, fun(_) -> {ok, [Tool]} end),
    meck:expect(erl_mcp_client, call, fun(_, _, _, _) ->
        {error, timeout}
    end),
    {ok, [KT]} = klotho_mcp:tools_from_client(self(), 5000),
    ?assertEqual({error, timeout}, (KT#klotho_tool.handler)(#{})).

handles_empty_list() ->
    meck:expect(erl_mcp_client, list_tools, fun(_) -> {ok, []} end),
    ?assertEqual({ok, []}, klotho_mcp:tools_from_client(self(), 5000)).

handles_undefined_desc() ->
    Tool = #mcp_client_tool{
        name = <<"t">>,
        raw_name = <<"t">>,
        description = undefined,
        input_schema = #{}
    },
    meck:expect(erl_mcp_client, list_tools, fun(_) -> {ok, [Tool]} end),
    {ok, [KT]} = klotho_mcp:tools_from_client(self(), 5000),
    ?assertEqual(<<>>, KT#klotho_tool.description).

handles_multi_part_content() ->
    Tool = #mcp_client_tool{
        name = <<"t">>,
        raw_name = <<"t">>,
        description = <<"T">>,
        input_schema = #{}
    },
    meck:expect(erl_mcp_client, list_tools, fun(_) -> {ok, [Tool]} end),
    %% Mix of text and non-text parts -- only text extracted
    meck:expect(erl_mcp_client, call, fun(_, _, _, _) ->
        {ok, #{<<"content">> => [
            #{<<"type">> => <<"text">>, <<"text">> => <<"hello">>},
            #{<<"type">> => <<"image">>, <<"data">> => <<"...">>},
            #{<<"type">> => <<"text">>, <<"text">> => <<"world">>}
        ]}}
    end),
    {ok, [KT]} = klotho_mcp:tools_from_client(self(), 5000),
    {ok, Result} = (KT#klotho_tool.handler)(#{}),
    ?assertEqual(<<"hello\nworld">>, Result).
