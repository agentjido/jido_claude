defmodule Jido.Claude.Actions.CancelSession do
  @moduledoc """
  Cancel a running Claude session.

  This action is called on the ClaudeSessionAgent itself to cancel
  its running session. For cancelling a child session from a parent
  agent, use `Jido.Claude.Parent.CancelSession` instead.

  ## Parameters

    * `reason` - Optional. Reason for cancellation. Default: `:cancelled`

  ## Example

      cmd(agent, {CancelSession, %{reason: :timeout}})

  """

  use Jido.Action,
    name: "claude_cancel_session",
    description: "Cancel a running Claude session",
    schema: [
      reason: [type: :atom, default: :cancelled]
    ]

  @compile {:no_warn_undefined, {Jido.Agent.Directive, :emit_to_parent, 2}}
  @compile {:no_warn_undefined, {Jido.Agent.Directive, :stop, 1}}

  alias Jido.Agent.Directive
  alias Jido.Claude.Signals

  @impl true
  def run(params, context) do
    agent = context[:agent]
    status = if agent, do: agent.state.status, else: :idle
    session_id = if agent, do: agent.state.session_id, else: nil

    if status == :running do
      cancel_error = cancel_runner(agent)

      state = %{
        status: :cancelled,
        error:
          %{
            type: :cancelled,
            reason: params.reason
          }
          |> maybe_put_cancel_error(cancel_error)
      }

      signal = Signals.session_error(session_id, :cancelled, %{reason: params.reason})

      directives = [
        Directive.emit_to_parent(agent, signal),
        Directive.stop(params.reason)
      ]

      {:ok, state, directives}
    else
      {:error, :session_not_running}
    end
  end

  defp cancel_runner(nil), do: nil

  defp cancel_runner(agent) do
    executor_module = agent.state[:executor_module] || Jido.Claude.Executor.Local
    runner_ref = agent.state[:runner_ref]

    case executor_module.cancel(runner_ref) do
      :ok -> nil
      {:error, reason} -> reason
      other -> {:unexpected_cancel_result, other}
    end
  rescue
    error ->
      {:cancel_exception, Exception.message(error)}
  end

  defp maybe_put_cancel_error(error_map, nil), do: error_map
  defp maybe_put_cancel_error(error_map, reason), do: Map.put(error_map, :cancel_error, reason)
end
