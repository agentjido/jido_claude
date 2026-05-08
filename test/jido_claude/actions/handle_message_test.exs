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

    test "accepts fully string keyed params from JSON transport" do
      params = %{
        "type" => "system",
        "subtype" => "init",
        "data" => %{
          "agents" => [],
          "session_id" => "session-789",
          "model" => "claude-haiku"
        },
        "raw" => %{}
      }

      assert {:ok, validated} = HandleMessage.validate_params(params)
      assert validated.type == :system
      assert validated.subtype == :init
      assert Enum.all?(Map.keys(validated.data), &is_atom/1)
      assert validated.data.session_id == "session-789"

      assert {:ok, state, _directives} = HandleMessage.run(validated, %{})
      assert state.session_id == "session-789"
      assert state.model == "claude-haiku"
    end

    test "normalizes string message type values without creating dynamic atoms" do
      params = %{
        "type" => "future_message_type",
        "data" => %{
          "session_id" => "session-unknown",
          "not_a_known_key_#{System.unique_integer([:positive])}" => "ignored"
        }
      }

      assert {:ok, validated} = HandleMessage.validate_params(params)
      assert validated.type == :unknown
      assert validated.subtype == nil
      assert validated.data == %{session_id: "session-unknown"}

      assert {:ok, %{}, []} = HandleMessage.run(validated, %{})
    end

    test "preserves atom-keyed params over duplicate string-keyed params" do
      params = %{
        "type" => "assistant",
        "subtype" => nil,
        "data" => %{"session_id" => "wrong", "model" => "wrong"},
        type: :system,
        subtype: :init,
        data: %{session_id: "session-atom", model: "claude-sonnet"}
      }

      assert {:ok, validated} = HandleMessage.validate_params(params)
      assert validated.type == :system
      assert validated.subtype == :init
      assert validated.data.session_id == "session-atom"

      assert {:ok, state, _directives} = HandleMessage.run(validated, %{})
      assert state.session_id == "session-atom"
      assert state.model == "claude-sonnet"
    end

    test "treats error_during_execution result frames as terminal failures" do
      params = %{
        "type" => "result",
        "subtype" => "error_during_execution",
        "data" => %{
          "session_id" => "session-error",
          "error" => "Claude CLI exited with code 1",
          "is_error" => true
        },
        "raw" => %{}
      }

      assert {:ok, validated} = HandleMessage.validate_params(params)
      assert validated.type == :result
      assert validated.subtype == :error_during_execution
      assert validated.data.error == "Claude CLI exited with code 1"

      assert {:ok, state, directives} = HandleMessage.run(validated, %{session_id: "session-error"})
      assert state.status == :failure
      assert state.error.type == :error_during_execution
      assert Enum.any?(directives, &match?(%Jido.Agent.Directive.Stop{reason: :normal}, &1))
    end
  end
end
