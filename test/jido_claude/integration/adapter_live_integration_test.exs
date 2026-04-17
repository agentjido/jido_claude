defmodule Jido.Claude.Integration.AdapterLiveIntegrationTest do
  use ExUnit.Case, async: false
  use Jido.Claude.LocalCLIIntegrationCase

  alias Jido.Claude.Adapter
  alias Jido.Harness.RunRequest

  @integration_skip_reason Jido.Claude.LocalCLIIntegrationCase.skip_reason()

  if @integration_skip_reason do
    @moduletag skip: @integration_skip_reason
  end

  test "adapter emits a terminal harness event via the local Claude CLI", ctx do
    attrs =
      %{
        prompt: ctx.prompt,
        cwd: ctx.cwd,
        max_turns: ctx.max_turns,
        timeout_ms: ctx.timeout_ms,
        metadata: %{}
      }
      |> maybe_put(:model, ctx.model)

    request = RunRequest.new!(attrs)

    assert {:ok, stream} = Adapter.run(request)
    events = Enum.to_list(stream)

    assert events != []
    assert Enum.all?(events, &(&1.provider == :claude))
    assert Enum.any?(events, &(&1.type == :session_started))

    terminal =
      Enum.find(events, fn event ->
        event.type in [:session_completed, :session_failed]
      end)

    assert terminal

    if ctx.require_success? do
      assert terminal.type == :session_completed
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
