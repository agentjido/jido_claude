defmodule JidoClaude.Actions.StartSessionTest do
  use ExUnit.Case, async: true

  alias JidoClaude.Actions.StartSession

  defmodule FakeExecutor do
    def start(args) do
      send(self(), {:fake_executor_started, args})

      {:ok, %{pid: self(), marker: :runner}, %{shell_session_id: "shell-session-123", shell_backend: "FakeBackend"}}
    end

    def cancel(_runner_ref), do: :ok
  end

  test "starts with configured executor and stores runner metadata" do
    params =
      base_params(%{
        prompt: "run via shell",
        target: :shell,
        shell: %{
          workspace_id: "workspace-1"
        },
        execution_context: %{
          limits: %{max_runtime_ms: 10_000}
        }
      })

    context = %{
      agent_pid: self(),
      session_id: "claude-session-1",
      executor_module: FakeExecutor
    }

    assert {:ok, state, []} = StartSession.run(params, context)

    assert_received {:fake_executor_started, args}
    assert args.agent_pid == self()
    assert args.prompt == "run via shell"
    assert args.target == :shell
    assert args.shell.workspace_id == "workspace-1"

    assert state.status == :running
    assert state.execution_target == :shell
    assert state.executor_module == FakeExecutor
    assert state.session_id == "claude-session-1"
    assert state.runner_ref.marker == :runner
    assert state.shell_session_id == "shell-session-123"
    assert state.shell_backend == "FakeBackend"
  end

  test "returns an error for unsupported execution targets" do
    params = base_params(%{target: :unsupported_target})

    assert {:error, {:unsupported_execution_target, :unsupported_target}} =
             StartSession.run(params, %{})
  end

  defp base_params(overrides) do
    Map.merge(
      %{
        prompt: "Analyze this codebase",
        model: "sonnet",
        max_turns: 25,
        allowed_tools: ["Read", "Glob", "Grep", "Bash"],
        cwd: nil,
        system_prompt: nil,
        sdk_timeout_ms: 600_000,
        target: :local,
        shell: %{},
        execution_context: %{}
      },
      overrides
    )
  end
end
