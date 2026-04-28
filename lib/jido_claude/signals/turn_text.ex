defmodule Jido.Claude.Signals.TurnText do
  @moduledoc """
  `claude.turn.text` signal emitted for assistant text output.
  """

  use Jido.Signal,
    type: "claude.turn.text",
    default_source: "/claude",
    extension_policy: [
      {Jido.Signal.Ext.Trace, :optional},
      {Jido.Signal.Ext.Dispatch, :optional}
    ],
    schema: [
      session_id: [type: :string, required: false],
      text: [type: :string, required: false]
    ]
end
