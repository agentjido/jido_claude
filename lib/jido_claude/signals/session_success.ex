defmodule Jido.Claude.Signals.SessionSuccess do
  @moduledoc """
  `claude.session.success` signal emitted when a session completes successfully.
  """

  use Jido.Signal,
    type: "claude.session.success",
    default_source: "/claude",
    extension_policy: [
      {Jido.Signal.Ext.Trace, :optional},
      {Jido.Signal.Ext.Dispatch, :optional}
    ],
    schema: [
      session_id: [type: :string, required: false],
      result: [type: :any, required: false],
      turns: [type: :integer, required: false],
      cost_usd: [type: :any, required: false],
      duration_ms: [type: :integer, required: false]
    ]
end
