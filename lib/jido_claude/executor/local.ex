defmodule Jido.Claude.Executor.Local do
  @moduledoc """
  Local executor that delegates to the existing Claude SDK stream runner.
  """

  @behaviour Jido.Claude.Executor

  alias Jido.Claude.StreamRunner

  @impl true
  def start(%{agent_pid: agent_pid, prompt: prompt, options: options}) do
    case Task.start(fn ->
           StreamRunner.run(%{
             agent_pid: agent_pid,
             prompt: prompt,
             options: options
           })
         end) do
      {:ok, pid} ->
        {:ok, %{pid: pid}, %{}}

      {:error, reason} ->
        {:error, {:local_executor_start_failed, reason}}
    end
  end

  @impl true
  def cancel(%{pid: pid}) when is_pid(pid) do
    if Process.alive?(pid) do
      Process.exit(pid, :shutdown)
    end

    :ok
  end

  def cancel(pid) when is_pid(pid) do
    cancel(%{pid: pid})
  end

  def cancel(nil), do: :ok
  def cancel(_), do: {:error, :invalid_runner_ref}
end
