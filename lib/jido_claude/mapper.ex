defmodule JidoClaude.Mapper do
  @moduledoc """
  Maps Claude SDK messages to normalized `Jido.Harness.Event` structs.
  """

  alias ClaudeAgentSDK.Message
  alias Jido.Harness.Event

  @spec map_message(term()) :: {:ok, [Event.t()]} | {:error, term()}
  def map_message(%Message{type: :system, subtype: :init, data: data} = message) when is_map(data) do
    payload = %{
      "cwd" => map_get(data, :cwd),
      "model" => map_get(data, :model),
      "tools" => map_get(data, :tools, [])
    }

    {:ok, [build_event(:session_started, map_get(data, :session_id), payload, message)]}
  end

  def map_message(%Message{type: :assistant, data: data} = message) when is_map(data) do
    session_id = map_get(data, :session_id)
    blocks = Message.content_blocks(message)

    events =
      if blocks == [] do
        maybe_assistant_text_event(data, session_id, message)
      else
        Enum.flat_map(blocks, &map_assistant_block(&1, session_id, message))
      end

    {:ok, events}
  end

  def map_message(%Message{type: :result, subtype: :success, data: data} = message) when is_map(data) do
    payload = %{
      "result" => map_get(data, :result),
      "num_turns" => map_get(data, :num_turns),
      "duration_ms" => map_get(data, :duration_ms),
      "is_error" => map_get(data, :is_error, false)
    }

    {:ok, [build_event(:session_completed, map_get(data, :session_id), payload, message)]}
  end

  def map_message(%Message{type: :result, data: data} = message) when is_map(data) do
    payload = %{
      "error" => map_get(data, :error) || map_get(data, :result),
      "subtype" => to_string(message.subtype || "error")
    }

    {:ok, [build_event(:session_failed, map_get(data, :session_id), payload, message)]}
  end

  def map_message(%Message{type: :stream_event, data: data} = message) when is_map(data) do
    event = map_get(data, :event, %{})

    text =
      event
      |> map_get(:delta, %{})
      |> map_get(:text)

    events =
      if is_binary(text) and text != "" do
        [build_event(:output_text_delta, map_get(data, :session_id), %{"text" => text}, message)]
      else
        [build_event(:provider_event, map_get(data, :session_id), %{"event" => inspect(event)}, message)]
      end

    {:ok, events}
  end

  def map_message(%Message{} = message) do
    {:ok, [build_event(:provider_event, nil, %{"type" => to_string(message.type)}, message)]}
  end

  def map_message(other) do
    {:error, {:unsupported_message, other}}
  end

  defp map_assistant_block(%{type: :text, text: text}, session_id, message) when is_binary(text) do
    [build_event(:output_text_delta, session_id, %{"text" => text}, message)]
  end

  defp map_assistant_block(%{type: :thinking, thinking: thinking}, session_id, message) when is_binary(thinking) do
    [build_event(:thinking_delta, session_id, %{"text" => thinking}, message)]
  end

  defp map_assistant_block(%{type: :tool_use, name: name, input: input, id: id}, session_id, message) do
    [build_event(:tool_call, session_id, %{"name" => name, "input" => input || %{}, "call_id" => id}, message)]
  end

  defp map_assistant_block(%{type: :tool_result, content: content, tool_use_id: tool_use_id, is_error: is_error}, session_id, message) do
    [
      build_event(
        :tool_result,
        session_id,
        %{"output" => content, "call_id" => tool_use_id, "is_error" => is_error},
        message
      )
    ]
  end

  defp map_assistant_block(_block, _session_id, _message), do: []

  defp maybe_assistant_text_event(data, session_id, message) do
    text =
      data
      |> map_get(:message, %{})
      |> map_get(:content)
      |> case do
        content when is_binary(content) -> content
        _ -> nil
      end

    if is_binary(text) and text != "" do
      [build_event(:output_text_delta, session_id, %{"text" => text}, message)]
    else
      []
    end
  end

  defp build_event(type, session_id, payload, raw) do
    Event.new!(%{
      type: type,
      provider: :claude,
      session_id: session_id,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      payload: stringify_keys(payload || %{}),
      raw: raw
    })
  end

  defp stringify_keys(map) when is_map(map) do
    map
    |> Enum.map(fn {k, v} -> {to_string(k), stringify_keys(v)} end)
    |> Map.new()
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp map_get(map, key, default \\ nil) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end
end
