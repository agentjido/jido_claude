defmodule Jido.Claude.Executor do
  @moduledoc """
  Behaviour for Claude execution backends.

  Executors are responsible for starting and cancelling a single Claude run
  while preserving the `claude.internal.message` signal contract consumed by
  `Jido.Claude.Actions.HandleMessage`.
  """

  @typedoc "Opaque runner reference used for cancellation."
  @type runner_ref :: term()

  @typedoc "Executor startup payload from StartSession."
  @type start_args :: %{
          required(:agent_pid) => pid(),
          required(:prompt) => String.t(),
          required(:options) => map(),
          required(:target) => atom(),
          optional(:shell) => map(),
          optional(:execution_context) => map()
        }

  @typedoc "Executor metadata persisted on the agent state."
  @type metadata :: map()

  @callback start(start_args()) :: {:ok, runner_ref(), metadata()} | {:error, term()}
  @callback cancel(runner_ref()) :: :ok | {:error, term()}
end
