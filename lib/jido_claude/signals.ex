defmodule JidoClaude.Signals do
  @moduledoc """
  Signal builders for Claude session events.

  All signals include `session_id` for parent correlation across multiple
  concurrent sessions.
  """

  alias Jido.Signal

  @doc """
  Signal emitted when a Claude session is initialized.
  """
  def session_started(data) do
    Signal.new!(%{
      type: "claude.session.started",
      source: "/claude",
      data: %{
        session_id: data[:session_id],
        model: data[:model]
      }
    })
  end

  @doc """
  Signal emitted when Claude produces a text response.
  """
  def assistant_text(session_id, %{text: text}) do
    Signal.new!(%{
      type: "claude.turn.text",
      source: "/claude",
      data: %{
        session_id: session_id,
        text: text
      }
    })
  end

  @doc """
  Signal emitted when Claude calls a tool.
  """
  def tool_use(session_id, %{name: name, input: input}) do
    Signal.new!(%{
      type: "claude.turn.tool_use",
      source: "/claude",
      data: %{
        session_id: session_id,
        tool: name,
        input: input
      }
    })
  end

  @doc """
  Signal emitted when a tool execution completes.
  """
  def tool_result(session_id, data) do
    Signal.new!(%{
      type: "claude.turn.tool_result",
      source: "/claude",
      data: Map.put(data, :session_id, session_id)
    })
  end

  @doc """
  Signal emitted when a Claude session completes successfully.
  """
  def session_success(data) do
    Signal.new!(%{
      type: "claude.session.success",
      source: "/claude",
      data: %{
        session_id: data[:session_id],
        result: data[:result],
        turns: data[:num_turns],
        cost_usd: data[:total_cost_usd],
        duration_ms: data[:duration_ms]
      }
    })
  end

  @doc """
  Signal emitted when a Claude session fails.
  """
  def session_error(session_id, subtype, data) do
    Signal.new!(%{
      type: "claude.session.error",
      source: "/claude",
      data: %{
        session_id: session_id,
        error_type: subtype,
        details: data
      }
    })
  end
end
