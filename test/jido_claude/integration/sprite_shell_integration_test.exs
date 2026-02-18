defmodule JidoClaude.Integration.SpriteShellIntegrationTest do
  use ExUnit.Case, async: false
  use JidoClaude.LiveIntegrationCase

  alias Jido.Signal
  alias JidoClaude.Actions.StartSession

  @terminal_subtypes [:success, :error_exception, :error_max_turns, :error_timeout]
  @integration_skip_reason JidoClaude.LiveIntegrationCase.skip_reason()

  if @integration_skip_reason do
    @moduletag skip: @integration_skip_reason
  end

  test "target :sprite starts via shell executor and emits terminal claude message", ctx do
    session_id = unique_name("claude-session")

    params = %{
      prompt: "Reply with exactly one word: READY",
      model: "sonnet",
      max_turns: 1,
      allowed_tools: ["Read", "Glob", "Grep", "Bash"],
      cwd: "/",
      system_prompt: nil,
      sdk_timeout_ms: 180_000,
      target: :sprite,
      shell: %{
        workspace_id: unique_name("claude-ws"),
        startup_timeout_ms: 45_000,
        receive_timeout_ms: 180_000,
        sprite: sprite_backend_config(ctx.sprite_token, ctx.sprite_base_url)
      },
      execution_context: %{
        limits: %{
          max_runtime_ms: 180_000,
          max_output_bytes: 1_000_000
        }
      }
    }

    assert {:ok, state, []} =
             StartSession.run(params, %{
               agent_pid: self(),
               session_id: session_id
             })

    on_exit(fn ->
      _ = state.executor_module.cancel(state.runner_ref)
    end)

    assert state.execution_target == :sprite
    assert is_binary(state.shell_session_id)
    assert is_binary(state.shell_workspace_id)
    assert is_binary(state.shell_backend)

    {messages, terminal} = collect_until_terminal(180_000)

    assert messages != []
    assert terminal
    assert message_type(terminal) == :result
    assert message_subtype(terminal) in @terminal_subtypes

    if ctx.require_success? do
      assert message_subtype(terminal) == :success
    end
  end

  defp sprite_backend_config(token, base_url) do
    %{
      sprite_name: unique_sprite_name(),
      token: token,
      create: true
    }
    |> maybe_put(:base_url, base_url)
  end

  defp unique_sprite_name do
    prefix = sprite_name()
    suffix = System.unique_integer([:positive, :monotonic])
    "#{prefix}-#{suffix}"
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp collect_until_terminal(timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_collect_until_terminal([], deadline)
  end

  defp do_collect_until_terminal(messages, deadline_ms) do
    now_ms = System.monotonic_time(:millisecond)
    remaining_ms = max(deadline_ms - now_ms, 0)

    if remaining_ms == 0 do
      flunk("timed out waiting for Claude terminal message via sprite backend")
    end

    receive do
      {:signal, %Signal{type: "claude.internal.message", data: data}} ->
        updated_messages = [data | messages]

        if terminal_message?(data) do
          {Enum.reverse(updated_messages), data}
        else
          do_collect_until_terminal(updated_messages, deadline_ms)
        end

      _other ->
        do_collect_until_terminal(messages, deadline_ms)
    after
      remaining_ms ->
        flunk("timed out waiting for Claude internal stream signal")
    end
  end

  defp terminal_message?(message) do
    message_type(message) == :result and message_subtype(message) in @terminal_subtypes
  end

  defp message_type(message), do: map_value(message, :type)
  defp message_subtype(message), do: map_value(message, :subtype)

  defp map_value(data, key) when is_map(data) do
    case Map.fetch(data, key) do
      {:ok, value} -> value
      :error -> Map.get(data, Atom.to_string(key))
    end
  end

  defp map_value(_data, _key), do: nil
end
