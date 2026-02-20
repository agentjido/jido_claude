defmodule Jido.Claude.CLI.RunnerTest do
  use ExUnit.Case, async: false

  alias Jido.Claude.CLI.Runner
  alias Jido.Claude.CLI.Runner.Result

  @timeout_probe_name :jido_claude_cli_runner_timeout_probe

  defmodule UnsupportedSessionServer do
  end

  defmodule TimeoutSessionServer do
    def subscribe(_session_id, _pid), do: {:ok, :subscribed}
    def unsubscribe(_session_id, _pid), do: {:ok, :unsubscribed}
    def run_command(_session_id, _line, _opts), do: {:ok, :accepted}

    def cancel(session_id) do
      if pid = Process.whereis(:jido_claude_cli_runner_timeout_probe) do
        send(pid, {:cancel_called, session_id})
      end

      {:ok, :cancelled}
    end
  end

  defmodule SuccessShellAgent do
    def run(_session_id, command, _opts \\ []) do
      cond do
        String.contains?(command, "cat >") ->
          {:ok, "ok"}

        String.contains?(command, "claude -p") ->
          {:ok,
           [
             Jason.encode!(%{"type" => "system", "subtype" => "init", "model" => "glm-4.7"}),
             Jason.encode!(%{
               "type" => "result",
               "subtype" => "success",
               "result" => "investigation complete",
               "num_turns" => 3,
               "duration_ms" => 1234,
               "total_cost_usd" => 0.01
             })
           ]
           |> Enum.join("\n")}

        true ->
          {:ok, "ok"}
      end
    end
  end

  defmodule AssistantOnlyShellAgent do
    def run(_session_id, command, _opts \\ []) do
      cond do
        String.contains?(command, "cat >") ->
          {:ok, "ok"}

        String.contains?(command, "claude -p") ->
          {:ok,
           Jason.encode!(%{
             "type" => "assistant",
             "message" => %{"content" => [%{"type" => "text", "text" => "assistant fallback"}]}
           })}

        true ->
          {:ok, "ok"}
      end
    end
  end

  defmodule RawLineShellAgent do
    def run(_session_id, command, _opts \\ []) do
      cond do
        String.contains?(command, "cat >") ->
          {:ok, "ok"}

        String.contains?(command, "claude -p") ->
          {:ok,
           Jason.encode!(%{"type" => "system"}) <>
             "\nNOT_JSON\n" <> Jason.encode!(%{"type" => "result", "result" => "ok"})}

        true ->
          {:ok, "ok"}
      end
    end
  end

  defmodule PromptFailShellAgent do
    def run(_session_id, command, _opts \\ []) do
      if String.contains?(command, "cat >") do
        {:error, :permission_denied}
      else
        {:ok, "ok"}
      end
    end
  end

  test "run_in_shell/4 returns parsed result and metadata" do
    assert {:ok, %Result{} = result} =
             Runner.run_in_shell("sess-1", "/work/repo", "Investigate issue",
               shell_agent_mod: SuccessShellAgent,
               shell_session_server_mod: UnsupportedSessionServer
             )

    assert result.status == :ok
    assert result.result_text == "investigation complete"
    assert result.metadata.model == "glm-4.7"
    assert result.metadata.turns == 3
  end

  test "run_in_shell/4 falls back to assistant text when result event is missing" do
    assert {:ok, %Result{} = result} =
             Runner.run_in_shell("sess-2", "/work/repo", "Investigate issue",
               shell_agent_mod: AssistantOnlyShellAgent,
               shell_session_server_mod: UnsupportedSessionServer
             )

    assert result.status == :ok
    assert result.result_text == "assistant fallback"
  end

  test "run_in_shell/4 emits raw line callback for non-json lines" do
    parent = self()

    assert {:ok, %Result{} = result} =
             Runner.run_in_shell("sess-3", "/work/repo", "Investigate issue",
               shell_agent_mod: RawLineShellAgent,
               shell_session_server_mod: UnsupportedSessionServer,
               on_raw_line: fn line -> send(parent, {:raw_line, line}) end
             )

    assert result.status == :ok
    assert_receive {:raw_line, "NOT_JSON"}
  end

  test "run_in_shell/4 returns prompt_write_failed on prompt materialization errors" do
    assert {:error, {:prompt_write_failed, :permission_denied}} =
             Runner.run_in_shell("sess-4", "/work/repo", "Investigate issue",
               shell_agent_mod: PromptFailShellAgent,
               shell_session_server_mod: UnsupportedSessionServer
             )
  end

  test "timeout does not invoke cancel callback" do
    Process.register(self(), @timeout_probe_name)

    assert {:error, :timeout} =
             Runner.run_in_shell("sess-timeout", "/work/repo", "Investigate issue",
               timeout: 50,
               shell_agent_mod: SuccessShellAgent,
               shell_session_server_mod: TimeoutSessionServer
             )

    refute_receive {:cancel_called, "sess-timeout"}
  after
    if Process.whereis(@timeout_probe_name) == self(), do: Process.unregister(@timeout_probe_name)
  end
end
