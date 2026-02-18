defmodule JidoClaude.ClaudeSessionAgent do
  @moduledoc """
  Agent that manages a single Claude Code session lifecycle.

  The ClaudeSessionAgent owns a single Claude session and emits signals
  for each turn. It is designed to be spawned as a child of a parent
  orchestrator agent.

  ## State

  The agent maintains the following state:

    * `status` - Current session status (`:idle`, `:running`, `:success`, `:failure`)
    * `session_id` - Unique identifier for this session
    * `prompt` - The original prompt sent to Claude
    * `options` - SDK options used for the session
    * `execution_target` - Runtime target (`:local`, `:shell`, `:sprite`)
    * `executor_module` - Executor module handling process lifecycle
    * `runner_ref` - Opaque executor-specific cancellation handle
    * `shell_session_id` - Shell session id when using shell-backed execution
    * `shell_workspace_id` - Shell workspace id when using shell-backed execution
    * `shell_backend` - Shell backend module name when using shell-backed execution
    * `model` - Model name (populated after session init)
    * `turns` - Number of turns completed
    * `transcript` - List of messages exchanged
    * `result` - Final result text (on success)
    * `cost_usd` - Total cost in USD (on completion)
    * `error` - Error details (on failure)

  ## Signal Routes

  The agent routes internal messages from the StreamRunner:

    * `claude.internal.message` → HandleMessage action

  ## Usage

      # Start as child of parent agent
      Directive.spawn_agent(
        ClaudeSessionAgent,
        "session-123",
        opts: %{
          initial_state: %{
            session_id: "session-123",
            prompt: "Analyze this codebase"
          }
        }
      )

  """

  use Jido.Agent,
    name: "claude_session",
    description: "Manages a single Claude Code session",
    schema: [
      status: [type: :atom, default: :idle],
      prompt: [type: :string, default: nil],
      options: [type: :any, default: nil],
      session_id: [type: :string, default: nil],
      execution_target: [type: :atom, default: :local],
      executor_module: [type: :any, default: nil],
      runner_ref: [type: :any, default: nil],
      shell_session_id: [type: :string, default: nil],
      shell_workspace_id: [type: :string, default: nil],
      shell_backend: [type: :string, default: nil],
      model: [type: :string, default: nil],
      turns: [type: :integer, default: 0],
      transcript: [type: {:list, :any}, default: []],
      result: [type: :string, default: nil],
      cost_usd: [type: :float, default: nil],
      error: [type: :any, default: nil]
    ]

  @spec plugin_specs() :: [Jido.Plugin.Spec.t()]
  def plugin_specs do
    super()
    |> Enum.map(fn %Jido.Plugin.Spec{} = spec ->
      %Jido.Plugin.Spec{
        spec
        | description: spec.description || "",
          category: spec.category || "",
          vsn: spec.vsn || ""
      }
    end)
  end

  def signal_routes do
    [
      {"claude.internal.message", {JidoClaude.Actions.HandleMessage, %{}}}
    ]
  end

  def actions do
    [
      JidoClaude.Actions.StartSession,
      JidoClaude.Actions.HandleMessage,
      JidoClaude.Actions.CancelSession
    ]
  end
end
