defmodule Jido.Claude.Signals.TurnToolResult do
  @moduledoc """
  `claude.turn.tool_result` signal emitted for tool execution output.

  Payload is intentionally unconstrained because upstream tool result shapes
  vary by tool and transport.
  """

  use Jido.Signal,
    type: "claude.turn.tool_result",
    default_source: "/claude"
end
