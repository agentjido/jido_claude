defmodule JidoClaude.Signals.SessionStarted do
  @moduledoc """
  `claude.session.started` signal emitted when a Claude session initializes.
  """

  use Jido.Signal,
    type: "claude.session.started",
    default_source: "/claude",
    schema: [
      session_id: [type: :string, required: false],
      model: [type: :string, required: false]
    ]
end
