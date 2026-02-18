defmodule JidoClaude.Signals.SessionError do
  @moduledoc """
  `claude.session.error` signal emitted when a session fails or is cancelled.
  """

  use Jido.Signal,
    type: "claude.session.error",
    default_source: "/claude",
    schema: [
      session_id: [type: :string, required: false],
      error_type: [type: :any, required: false],
      details: [type: :any, required: false]
    ]
end
