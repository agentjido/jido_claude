defmodule Jido.Claude.Signals.TurnToolUse do
  @moduledoc """
  `claude.turn.tool_use` signal emitted when Claude requests a tool call.
  """

  use Jido.Signal,
    type: "claude.turn.tool_use",
    default_source: "/claude",
    extension_policy: [
      {Jido.Signal.Ext.Trace, :optional},
      {Jido.Signal.Ext.Dispatch, :optional}
    ],
    schema: [
      session_id: [type: :string, required: false],
      tool: [type: :string, required: false],
      input: [type: :any, required: false]
    ]
end
