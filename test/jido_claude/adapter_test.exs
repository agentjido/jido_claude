defmodule Jido.Claude.AdapterTest do
  use ExUnit.Case, async: false

  use Jido.Harness.AdapterContract,
    adapter: Jido.Claude.Adapter,
    provider: :claude,
    check_run: true,
    run_request: %{prompt: "contract claude run", cwd: "/repo", metadata: %{}}

  alias ClaudeAgentSDK.Message
  alias Jido.Harness.RunRequest
  alias Jido.Claude.{Adapter, Error}

  defmodule StubSdk do
    def query(prompt, opts) do
      Application.get_env(:jido_claude, :stub_adapter_query, fn _prompt, _opts -> [] end).(prompt, opts)
    end

    def resume(session_id, prompt, opts) do
      Application.get_env(:jido_claude, :stub_adapter_resume, fn _session_id, _prompt, _opts -> [] end).(
        session_id,
        prompt,
        opts
      )
    end
  end

  setup do
    old_sdk = Application.get_env(:jido_claude, :sdk_module)
    old_query = Application.get_env(:jido_claude, :stub_adapter_query)
    old_resume = Application.get_env(:jido_claude, :stub_adapter_resume)

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

    Application.put_env(:jido_claude, :stub_adapter_resume, fn session_id, prompt, _opts ->
      send(self(), {:claude_resume, session_id, prompt})

      [
        %Message{
          type: :system,
          subtype: :init,
          data: %{
            session_id: session_id,
            cwd: "/repo",
            model: "sonnet",
            tools: ["Read", "Bash"]
          },
          raw: %{}
        },
        %Message{
          type: :result,
          subtype: :success,
          data: %{
            session_id: session_id,
            result: "Done",
            is_error: false,
            num_turns: 1
          },
          raw: %{}
        }
      ]
    end)

    on_exit(fn ->
      restore_env(:jido_claude, :sdk_module, old_sdk)
      restore_env(:jido_claude, :stub_adapter_query, old_query)
      restore_env(:jido_claude, :stub_adapter_resume, old_resume)
    end)

    :ok
  end

  test "id/0 and capabilities/0" do
    assert Adapter.id() == :claude
    caps = Adapter.capabilities()
    assert caps.streaming? == true
    assert caps.tool_calls? == true
    assert caps.resume? == true
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
    assert Enum.map(events, & &1.type) == [:session_started, :output_text_delta, :usage, :session_completed]
    assert Enum.all?(events, &(&1.provider == :claude))
  end

  test "run/2 resumes sdk session when request carries session_id" do
    request = RunRequest.new!(%{prompt: "continue", cwd: "/repo", session_id: "claude-session-2", metadata: %{}})

    assert {:ok, stream} = Adapter.run(request)
    events = Enum.to_list(stream)

    assert_receive {:claude_resume, "claude-session-2", "continue"}
    refute_received {:claude_query, _prompt}
    assert Enum.map(events, & &1.type) == [:session_started, :session_completed]
    assert Enum.all?(events, &(&1.session_id == "claude-session-2"))
  end

  test "run/2 rejects blank session_id" do
    request = RunRequest.new!(%{prompt: "continue", cwd: "/repo", session_id: " ", metadata: %{}})

    assert {:error, %Error.InvalidInputError{field: :session_id}} = Adapter.run(request)
  end

  test "run/2 returns structured validation errors for invalid request terms" do
    assert {:error, %Error.InvalidInputError{message: message, value: value}} =
             Adapter.run(:not_a_run_request, [])

    assert message =~ "expects %Jido.Harness.RunRequest{}"
    assert value == :not_a_run_request
  end

  test "run/2 returns structured validation errors for invalid adapter options" do
    request =
      RunRequest.new!(%{
        prompt: "triage issue #42",
        cwd: "/repo",
        metadata: %{
          "claude" => %{"output_format" => {:json_schema, :invalid_schema}}
        }
      })

    assert {:error, %Error.InvalidInputError{message: message, details: details}} =
             Adapter.run(request, [])

    assert message == "Invalid Claude adapter options"
    assert details[:details] =~ "output_format"
  end

  test "raw CLI compatibility decoder accepts null parent tool ids" do
    line =
      Jason.encode!(%{
        "type" => "assistant",
        "session_id" => "claude-session-1",
        "parent_tool_use_id" => nil,
        "message" => %{
          "content" => [%{"type" => "text", "text" => "ok"}]
        }
      })

    assert {:ok, %Message{type: :assistant, data: data}} =
             Jido.Claude.CLI.RawStream.__decode_line__(line)

    assert data.parent_tool_use_id == nil
    assert data.session_id == "claude-session-1"
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
