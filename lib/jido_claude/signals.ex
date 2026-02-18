defmodule JidoClaude.Signals do
  @moduledoc """
  Compatibility facade for Claude session signal constructors.

  Signal definitions live in dedicated modules under `JidoClaude.Signals.*`.
  """

  alias JidoClaude.Signals.SessionError
  alias JidoClaude.Signals.SessionStarted
  alias JidoClaude.Signals.SessionSuccess
  alias JidoClaude.Signals.TurnText
  alias JidoClaude.Signals.TurnToolResult
  alias JidoClaude.Signals.TurnToolUse

  @doc """
  Signal emitted when a Claude session is initialized.
  """
  def session_started(data) do
    %{
      session_id: map_value(data, :session_id),
      model: map_value(data, :model)
    }
    |> compact_map()
    |> SessionStarted.new!()
  end

  @doc """
  Signal emitted when Claude produces a text response.
  """
  def assistant_text(session_id, %{text: text}) do
    %{
      session_id: session_id,
      text: text
    }
    |> compact_map()
    |> TurnText.new!()
  end

  def assistant_text(session_id, data) when is_map(data) do
    assistant_text(session_id, %{text: map_value(data, :text)})
  end

  @doc """
  Signal emitted when Claude calls a tool.
  """
  def tool_use(session_id, %{name: name, input: input}) do
    %{
      session_id: session_id,
      tool: name,
      input: input
    }
    |> compact_map()
    |> TurnToolUse.new!()
  end

  def tool_use(session_id, data) when is_map(data) do
    tool_use(session_id, %{name: map_value(data, :name), input: map_value(data, :input)})
  end

  @doc """
  Signal emitted when a tool execution completes.
  """
  def tool_result(session_id, data) do
    data
    |> Map.put(:session_id, session_id)
    |> TurnToolResult.new!()
  end

  @doc """
  Signal emitted when a Claude session completes successfully.
  """
  def session_success(data) do
    %{
      session_id: map_value(data, :session_id),
      result: map_value(data, :result),
      turns: map_value(data, :num_turns),
      cost_usd: map_value(data, :total_cost_usd),
      duration_ms: map_value(data, :duration_ms)
    }
    |> compact_map()
    |> SessionSuccess.new!()
  end

  @doc """
  Signal emitted when a Claude session fails.
  """
  def session_error(session_id, subtype, data) do
    %{
      session_id: session_id,
      error_type: subtype,
      details: data
    }
    |> compact_map()
    |> SessionError.new!()
  end

  defp map_value(data, key) when is_map(data) do
    case Map.fetch(data, key) do
      {:ok, value} -> value
      :error -> Map.get(data, Atom.to_string(key))
    end
  end

  defp map_value(_data, _key), do: nil

  defp compact_map(map) when is_map(map) do
    Enum.reduce(map, %{}, fn
      {_key, nil}, acc -> acc
      {key, value}, acc -> Map.put(acc, key, value)
    end)
  end
end
