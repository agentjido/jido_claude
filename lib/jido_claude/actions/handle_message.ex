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

  @param_key_aliases %{
    "data" => :data,
    "raw" => :raw,
    "subtype" => :subtype,
    "type" => :type
  }

  @type_aliases %{
    "assistant" => :assistant,
    "rate_limit_event" => :rate_limit_event,
    "result" => :result,
    "stream_event" => :stream_event,
    "system" => :system,
    "unknown" => :unknown,
    "user" => :user
  }

  @subtype_aliases %{
    "error_during_execution" => :error_during_execution,
    "error_exception" => :error_exception,
    "error_max_turns" => :error_max_turns,
    "error_timeout" => :error_timeout,
    "init" => :init,
    "success" => :success,
    "task_notification" => :task_notification,
    "task_progress" => :task_progress,
    "task_started" => :task_started
  }

  @data_key_aliases %{
    "apiKeySource" => :api_key_source,
    "content" => :content,
    "cwd" => :cwd,
    "description" => :description,
    "duration_ms" => :duration_ms,
    "duration_api_ms" => :duration_api_ms,
    "error" => :error,
    "error_details" => :error_details,
    "error_struct" => :error_struct,
    "event" => :event,
    "is_error" => :is_error,
    "last_tool_name" => :last_tool_name,
    "mcp_servers" => :mcp_servers,
    "message" => :message,
    "model" => :model,
    "num_turns" => :num_turns,
    "output_file" => :output_file,
    "parent_tool_use_id" => :parent_tool_use_id,
    "permissionMode" => :permission_mode,
    "rate_limit_info" => :rate_limit_info,
    "request_id" => :request_id,
    "result" => :result,
    "session_id" => :session_id,
    "status" => :status,
    "stop_reason" => :stop_reason,
    "structured_output" => :structured_output,
    "subtype" => :subtype,
    "summary" => :summary,
    "task_id" => :task_id,
    "task_type" => :task_type,
    "tools" => :tools,
    "tool_use_id" => :tool_use_id,
    "tool_use_result" => :tool_use_result,
    "total_cost_usd" => :total_cost_usd,
    "type" => :type,
    "usage" => :usage,
    "uuid" => :uuid
  }

  @impl true
  def on_before_validate_params(params) when is_map(params) do
    params =
      params
      |> normalize_param_keys()
      |> maybe_update(:type, &normalize_message_type/1)
      |> maybe_update(:subtype, &normalize_message_subtype/1)
      |> maybe_update(:data, &normalize_data/1)

    {:ok, params}
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

  defp normalize_param_keys(params) do
    Enum.reduce(params, %{}, fn
      {key, value}, acc when is_atom(key) ->
        Map.put(acc, key, value)

      {key, value}, acc when is_binary(key) ->
        case Map.fetch(@param_key_aliases, key) do
          {:ok, atom_key} -> Map.put_new(acc, atom_key, value)
          :error -> Map.put(acc, key, value)
        end

      {key, value}, acc ->
        Map.put(acc, key, value)
    end)
  end

  defp normalize_message_type(type) when is_atom(type), do: type

  defp normalize_message_type(type) when is_binary(type) do
    Map.get(@type_aliases, type, :unknown)
  end

  defp normalize_message_type(type), do: type

  defp normalize_message_subtype(nil), do: nil
  defp normalize_message_subtype(subtype) when is_atom(subtype), do: subtype

  defp normalize_message_subtype(subtype) when is_binary(subtype) do
    case Map.fetch(@subtype_aliases, subtype) do
      {:ok, atom_subtype} -> atom_subtype
      :error -> if String.starts_with?(subtype, "error_"), do: :error_exception, else: :unknown
    end
  end

  defp normalize_message_subtype(subtype), do: subtype

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

  defp maybe_update(map, key, fun) do
    case Map.fetch(map, key) do
      {:ok, value} -> Map.put(map, key, fun.(value))
      :error -> map
    end
  end

  defp normalize_data_key(key) do
    case Map.fetch(@data_key_aliases, key) do
      {:ok, atom_key} -> {:ok, atom_key}
      :error -> :error
    end
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

  defp process_message(%{type: :result, subtype: subtype, data: data}, _agent, session_id) do
    if result_error_subtype?(subtype) do
      state = %{
        status: :failure,
        error: %{type: subtype, details: data}
      }

      signal = Signals.session_error(session_id, subtype, data)
      {state, [signal], true}
    else
      {%{}, [], false}
    end
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

  defp result_error_subtype?(subtype) when is_atom(subtype) do
    subtype
    |> Atom.to_string()
    |> String.starts_with?("error_")
  end

  defp result_error_subtype?(_subtype), do: false

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
