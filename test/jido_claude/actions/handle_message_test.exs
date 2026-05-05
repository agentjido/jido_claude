defmodule Jido.Claude.Actions.HandleMessageTest do
  use ExUnit.Case, async: true

  alias Jido.Claude.Actions.HandleMessage
  alias Jido.Claude.CLI.Parser

  describe "validate_params/1" do
    test "accepts mixed atom and string keyed SDK init data" do
      data =
        Map.merge(
          %{
            "agents" => [],
            "apiKeySource" => "none",
            "cwd" => "/tmp/project",
            "hooks" => [],
            "model" => "claude-sonnet",
            "permissionMode" => "default",
            "session_id" => "session-123"
          },
          %{
            api_key_source: "none",
            cwd: "/tmp/project",
            model: "claude-sonnet",
            permission_mode: "default",
            session_id: "session-123",
            tools: ["Read"]
          }
        )

      params = %{
        type: :system,
        subtype: :init,
        data: data,
        raw: %{"agents" => [], "session_id" => "session-123"}
      }

      assert {:ok, validated} = HandleMessage.validate_params(params)
      assert Enum.all?(Map.keys(validated.data), &is_atom/1)
      assert validated.data.session_id == "session-123"
      assert validated.data.model == "claude-sonnet"
      assert validated.data.cwd == "/tmp/project"
      refute Map.has_key?(validated.data, "agents")

      assert {:ok, state, _directives} = HandleMessage.run(validated, %{})
      assert state.session_id == "session-123"
      assert state.model == "claude-sonnet"
    end

    test "promotes known keys from raw string keyed parser data" do
      line =
        Jason.encode!(%{
          type: "system",
          subtype: "init",
          session_id: "session-456",
          model: "claude-opus",
          agents: []
        })

      assert {:ok, params} = Parser.decode_stream_line(line)
      assert {:ok, validated} = HandleMessage.validate_params(params)

      assert Enum.all?(Map.keys(validated.data), &is_atom/1)
      assert validated.data.session_id == "session-456"
      assert validated.data.model == "claude-opus"

      assert {:ok, state, _directives} = HandleMessage.run(validated, %{})
      assert state.session_id == "session-456"
      assert state.model == "claude-opus"
    end
  end
end
