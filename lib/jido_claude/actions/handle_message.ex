defmodule Jido.Claude.Actions.HandleMessage do
  @moduledoc """
  Process a message from the Claude SDK stream.

  This action handles internal messages dispatched by the StreamRunner
  and converts them into:
  1. State updates for the ClaudeSessionAgent
  2. Parent-facing signals for orchestration

  ## Message Types

    * `:system/:init` - Session initialized with model info
    * `:assistant` - Claude's response with text and/or tool calls
    * `:user` - Tool execution results
    * `:result/:success` - Session completed successfully
    * `:result/:error_*` - Session failed

  ## Parameters

    * `type` - Required. Message type atom.
    * `subtype` - Optional. Message subtype atom.
    * `data` - Optional. Message-specific data map.
    * `raw` - Optional. Original JSON from CLI.

  """

  use Jido.Action,
    name: "claude_handle_message",
    description: "Process a message from Claude SDK stream",
    schema: [
      type: [type: :atom, required: true],
      subtype: [type: :atom, default: nil],
      data: [type: :map, default: %{}],
      raw: [type: :any, default: nil]
    ]

  @compile {:no_warn_undefined, {Jido.Agent.Directive, :emit_to_parent, 2}}
  @compile {:no_warn_undefined, {Jido.Agent.Directive, :emit, 1}}
  @compile {:no_warn_undefined, {Jido.Agent.Directive, :stop, 1}}

  alias Jido.Agent.Directive
  alias Jido.Claude.Signals

  @data_key_aliases %{
    "apiKeySource" => :api_key_source,
    "cwd" => :cwd,
    "duration_ms" => :duration_ms,
    "duration_api_ms" => :duration_api_ms,
    "error" => :error,
    "is_error" => :is_error,
    "mcp_servers" => :mcp_servers,
    "message" => :message,
    "model" => :model,
    "num_turns" => :num_turns,
    "parent_tool_use_id" => :parent_tool_use_id,
    "permissionMode" => :permission_mode,
    "request_id" => :request_id,
    "result" => :result,
    "session_id" => :session_id,
    "subtype" => :subtype,
    "tools" => :tools,
    "tool_use_result" => :tool_use_result,
    "total_cost_usd" => :total_cost_usd,
    "type" => :type,
    "usage" => :usage,
    "uuid" => :uuid
  }

  @impl true
  def on_before_validate_params(%{data: data} = params) do
    {:ok, %{params | data: normalize_data(data)}}
  end

  def on_before_validate_params(params), do: {:ok, params}

  @impl true
  def run(params, context) do
    agent = context[:agent]
    session_id = get_session_id(agent, context)

    {state_update, parent_signals, terminal?} =
      process_message(params, agent, session_id)

    directives = build_directives(agent, parent_signals, terminal?)

    {:ok, state_update, directives}
  end

  defp normalize_data(data) when is_map(data) do
    Enum.reduce(data, %{}, fn
      {key, value}, acc when is_atom(key) ->
        Map.put(acc, key, value)

      {key, value}, acc when is_binary(key) ->
        case normalize_data_key(key) do
          {:ok, atom_key} -> Map.put_new(acc, atom_key, value)
          :error -> acc
        end

      _other, acc ->
        acc
    end)
  end

  defp normalize_data(data), do: data

  defp normalize_data_key(key) do
    case Map.fetch(@data_key_aliases, key) do
      {:ok, atom_key} -> {:ok, atom_key}
      :error -> existing_atom_key(key)
    end
  end

  defp existing_atom_key(key) do
    {:ok, String.to_existing_atom(key)}
  rescue
    ArgumentError -> :error
  end

  defp get_session_id(agent, context) do
    cond do
      context[:session_id] -> context.session_id
      agent && agent.state[:session_id] -> agent.state.session_id
      true -> nil
    end
  end

  defp process_message(%{type: :system, subtype: :init, data: data}, _agent, _session_id) do
    started_data = %{
      session_id: map_value(data, :session_id),
      model: map_value(data, :model)
    }

    state = %{
      session_id: started_data.session_id,
      model: started_data.model
    }

    signal = Signals.session_started(started_data)
    {state, [signal], false}
  end

  defp process_message(%{type: :assistant, raw: raw}, agent, session_id) do
    content_blocks = extract_content_blocks(raw)
    current_turns = if agent, do: agent.state.turns, else: 0
    current_transcript = if agent, do: agent.state.transcript, else: []

    state = %{
      turns: current_turns + 1,
      transcript: current_transcript ++ [{:assistant, content_blocks}]
    }

    signals =
      content_blocks
      |> Enum.map(fn
        %{type: :text} = block -> Signals.assistant_text(session_id, block)
        %{type: :tool_use} = block -> Signals.tool_use(session_id, block)
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)

    {state, signals, false}
  end

  defp process_message(%{type: :user, data: data}, agent, session_id) do
    current_transcript = if agent, do: agent.state.transcript, else: []

    state = %{
      transcript: current_transcript ++ [{:user, data}]
    }

    signal = Signals.tool_result(session_id, data)
    {state, [signal], false}
  end

  defp process_message(%{type: :result, subtype: :success, data: data}, _agent, _session_id) do
    success_data = %{
      session_id: map_value(data, :session_id),
      result: map_value(data, :result),
      num_turns: map_value(data, :num_turns),
      total_cost_usd: map_value(data, :total_cost_usd),
      duration_ms: map_value(data, :duration_ms)
    }

    state = %{
      status: :success,
      result: success_data.result,
      cost_usd: success_data.total_cost_usd
    }

    signal = Signals.session_success(success_data)
    {state, [signal], true}
  end

  defp process_message(%{type: :result, subtype: subtype, data: data}, _agent, session_id)
       when subtype in [:error_max_turns, :error_exception, :error_timeout] do
    state = %{
      status: :failure,
      error: %{type: subtype, details: data}
    }

    signal = Signals.session_error(session_id, subtype, data)
    {state, [signal], true}
  end

  defp process_message(_msg, _agent, _session_id) do
    {%{}, [], false}
  end

  defp build_directives(agent, signals, terminal?) do
    signal_directives =
      signals
      |> Enum.map(fn signal ->
        if agent do
          Directive.emit_to_parent(agent, signal)
        else
          Directive.emit(signal)
        end
      end)
      |> Enum.reject(&is_nil/1)

    if terminal? do
      signal_directives ++ [Directive.stop(:normal)]
    else
      signal_directives
    end
  end

  defp extract_content_blocks(%{"message" => %{"content" => content}}) when is_list(content) do
    Enum.map(content, fn
      %{"type" => "text", "text" => text} ->
        %{type: :text, text: text}

      %{"type" => "tool_use", "name" => name, "input" => input} ->
        %{type: :tool_use, name: name, input: input}

      other ->
        %{type: :unknown, raw: other}
    end)
  end

  defp extract_content_blocks(%{message: %{content: content}}) when is_list(content) do
    Enum.map(content, fn
      %{type: "text", text: text} ->
        %{type: :text, text: text}

      %{type: :text, text: text} ->
        %{type: :text, text: text}

      %{type: "tool_use", name: name, input: input} ->
        %{type: :tool_use, name: name, input: input}

      %{type: :tool_use, name: name, input: input} ->
        %{type: :tool_use, name: name, input: input}

      other ->
        %{type: :unknown, raw: other}
    end)
  end

  defp extract_content_blocks(_), do: []

  defp map_value(data, key) when is_map(data) do
    case Map.fetch(data, key) do
      {:ok, value} -> value
      :error -> Map.get(data, Atom.to_string(key))
    end
  end

  defp map_value(_data, _key), do: nil
end
