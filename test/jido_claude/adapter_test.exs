defmodule Jido.Claude.AdapterTest do
  use ExUnit.Case, async: false

  alias ClaudeAgentSDK.Message
  alias Jido.Harness.RunRequest
  alias Jido.Claude.Adapter

  defmodule StubSdk do
    def query(prompt, opts) do
      Application.get_env(:jido_claude, :stub_adapter_query, fn _prompt, _opts -> [] end).(prompt, opts)
    end
  end

  setup do
    old_sdk = Application.get_env(:jido_claude, :sdk_module)
    old_query = Application.get_env(:jido_claude, :stub_adapter_query)

    Application.put_env(:jido_claude, :sdk_module, StubSdk)

    Application.put_env(:jido_claude, :stub_adapter_query, fn prompt, _opts ->
      send(self(), {:claude_query, prompt})

      [
        %Message{
          type: :system,
          subtype: :init,
          data: %{
            session_id: "claude-session-1",
            cwd: "/repo",
            model: "sonnet",
            tools: ["Read", "Bash"]
          },
          raw: %{}
        },
        %Message{
          type: :assistant,
          subtype: nil,
          data: %{
            session_id: "claude-session-1",
            message: %{
              "content" => [
                %{"type" => "text", "text" => "Investigating..."}
              ]
            }
          },
          raw: %{}
        },
        %Message{
          type: :result,
          subtype: :success,
          data: %{
            session_id: "claude-session-1",
            result: "Done",
            is_error: false,
            num_turns: 1,
            duration_ms: 100
          },
          raw: %{}
        }
      ]
    end)

    on_exit(fn ->
      restore_env(:jido_claude, :sdk_module, old_sdk)
      restore_env(:jido_claude, :stub_adapter_query, old_query)
    end)

    :ok
  end

  test "id/0 and capabilities/0" do
    assert Adapter.id() == :claude
    caps = Adapter.capabilities()
    assert caps.streaming? == true
    assert caps.tool_calls? == true
  end

  test "runtime_contract/0 supports both anthropic and zai envs" do
    contract = Adapter.runtime_contract()
    assert contract.provider == :claude
    assert "ANTHROPIC_AUTH_TOKEN" in contract.host_env_required_any
    assert "CLAUDE_CODE_API_KEY" in contract.host_env_required_any
    assert "ANTHROPIC_BASE_URL" in contract.sprite_env_forward
  end

  test "run/2 maps sdk messages into harness events" do
    request = RunRequest.new!(%{prompt: "triage issue #42", cwd: "/repo", metadata: %{}})
    assert {:ok, stream} = Adapter.run(request)
    events = Enum.to_list(stream)

    assert_receive {:claude_query, "triage issue #42"}
    assert Enum.map(events, & &1.type) == [:session_started, :output_text_delta, :session_completed]
    assert Enum.all?(events, &(&1.provider == :claude))
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
