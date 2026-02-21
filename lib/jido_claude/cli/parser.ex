defmodule Jido.Claude.CLI.Parser do
  @moduledoc """
  Pure helpers for parsing Claude stream-json output.
  """

  @typedoc "Normalized Claude message shape used by shell-backed executors."
  @type normalized_message :: %{
          required(:type) => atom(),
          required(:subtype) => atom() | nil,
          required(:data) => map(),
          required(:raw) => map()
        }

  @doc """
  Parse one JSON line emitted by `claude --output-format stream-json`.
  """
  @spec decode_stream_line(String.t()) :: {:ok, normalized_message()} | {:error, term()}
  def decode_stream_line(line) when is_binary(line) do
    trimmed = String.trim(line)

    if trimmed == "" do
      {:error, :empty_line}
    else
      with {:ok, raw} <- Jason.decode(trimmed),
           true <- is_map(raw) do
        {:ok,
         %{
           type: normalize_message_type(map_get(raw, :type)),
           subtype: normalize_message_subtype(map_get(raw, :subtype)),
           data: extract_message_data(raw),
           raw: raw
         }}
      else
        false -> {:error, :invalid_json}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Return a compact event kind string for telemetry/logging.
  """
  @spec event_kind(map()) :: String.t()
  def event_kind(%{"type" => "stream_event", "event" => %{"type" => nested}})
      when is_binary(nested),
      do: "stream:#{nested}"

  def event_kind(%{"type" => type}) when is_binary(type), do: type
  def event_kind(%{type: type}) when is_atom(type), do: Atom.to_string(type)
  def event_kind(_), do: "unknown"

  @doc """
  Extract best-effort final response text from stream events.
  """
  @spec extract_result_text([map()], String.t() | nil) :: String.t() | nil
  def extract_result_text(events, raw_output) when is_list(events) do
    result_text =
      Enum.find_value(Enum.reverse(events), fn
        %{"type" => "result", "result" => result} when is_binary(result) ->
          String.trim(result)

        _ ->
          nil
      end)

    assistant_text =
      Enum.find_value(Enum.reverse(events), fn
        %{"type" => "assistant", "message" => %{"content" => content}} when is_list(content) ->
          content
          |> Enum.flat_map(fn
            %{"type" => "text", "text" => text} when is_binary(text) -> [text]
            _ -> []
          end)
          |> Enum.join("")
          |> String.trim()
          |> blank_to_nil()

        _ ->
          nil
      end)

    delta_text =
      events
      |> Enum.flat_map(fn
        %{
          "type" => "stream_event",
          "event" => %{"type" => "content_block_delta", "delta" => %{"text" => text}}
        }
        when is_binary(text) ->
          [text]

        _ ->
          []
      end)
      |> Enum.join("")
      |> String.trim()
      |> blank_to_nil()

    result_text || assistant_text || delta_text || raw_output_fallback(raw_output)
  end

  @doc """
  Extract summary metadata from stream events.
  """
  @spec extract_metadata([map()]) :: map()
  def extract_metadata(events) when is_list(events) do
    system_event = find_last_event(events, "system")
    result_event = find_last_event(events, "result")

    %{
      model: map_get(system_event || %{}, :model),
      cli_version: map_get(system_event || %{}, :claude_code_version),
      result_subtype: map_get(result_event || %{}, :subtype),
      turns: map_get(result_event || %{}, :num_turns),
      duration_ms: map_get(result_event || %{}, :duration_ms),
      cost_usd: map_get(result_event || %{}, :total_cost_usd)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp find_last_event(events, expected_type) do
    Enum.find(Enum.reverse(events), fn
      %{"type" => type} when is_binary(type) -> type == expected_type
      _ -> false
    end)
  end

  defp raw_output_fallback(value) when is_binary(value) do
    value
    |> String.trim()
    |> blank_to_nil()
  end

  defp raw_output_fallback(_), do: nil

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp extract_message_data(raw) when is_map(raw) do
    case map_get(raw, :data) do
      data when is_map(data) -> data
      nil -> raw
      other -> %{"value" => other}
    end
  end

  defp normalize_message_type(:system), do: :system
  defp normalize_message_type(:assistant), do: :assistant
  defp normalize_message_type(:user), do: :user
  defp normalize_message_type(:result), do: :result
  defp normalize_message_type("system"), do: :system
  defp normalize_message_type("assistant"), do: :assistant
  defp normalize_message_type("user"), do: :user
  defp normalize_message_type("result"), do: :result
  defp normalize_message_type(_), do: :unknown

  defp normalize_message_subtype(nil), do: nil
  defp normalize_message_subtype(:init), do: :init
  defp normalize_message_subtype(:success), do: :success
  defp normalize_message_subtype(:error_exception), do: :error_exception
  defp normalize_message_subtype(:error_max_turns), do: :error_max_turns
  defp normalize_message_subtype(:error_timeout), do: :error_timeout
  defp normalize_message_subtype("init"), do: :init
  defp normalize_message_subtype("success"), do: :success
  defp normalize_message_subtype("error_exception"), do: :error_exception
  defp normalize_message_subtype("error_max_turns"), do: :error_max_turns
  defp normalize_message_subtype("error_timeout"), do: :error_timeout

  defp normalize_message_subtype(subtype) when is_binary(subtype) do
    if String.starts_with?(subtype, "error_"), do: :error_exception, else: :unknown
  end

  defp normalize_message_subtype(_), do: :unknown

  defp map_get(map, key) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end
end
