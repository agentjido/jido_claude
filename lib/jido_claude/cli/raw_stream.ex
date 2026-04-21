defmodule Jido.Claude.CLI.RawStream do
  @moduledoc false

  alias ClaudeAgentSDK.{CLI, Message, Options}

  @default_timeout_ms 300_000

  @spec query(String.t(), Options.t()) :: Enumerable.t(Message.t())
  def query(prompt, %Options{} = options) when is_binary(prompt) do
    Stream.resource(
      fn -> run(prompt, options) end,
      &next/1,
      fn _ -> :ok end
    )
  end

  defp run(prompt, %Options{} = options) do
    timeout_ms = options.timeout_ms || @default_timeout_ms

    task =
      Task.async(fn ->
        program = CLI.resolve_executable!(options)
        args = ["-p", prompt] ++ Options.to_args(options)
        command = shell_join([program | args]) <> " < /dev/null"

        cmd_opts =
          [stderr_to_stdout: false]
          |> maybe_put_cmd_opt(:cd, options.cwd)
          |> maybe_put_cmd_opt(:env, env_list(options.env))

        System.cmd("/bin/sh", ["-c", command], cmd_opts)
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {stdout, 0}} ->
        stdout
        |> decode_stdout()
        |> ensure_result()

      {:ok, {stdout, exit_code}} ->
        decode_stdout(stdout) ++ [Message.error_result("Claude CLI exited with code #{exit_code}")]

      nil ->
        [Message.error_result("Claude CLI timed out after #{timeout_ms}ms")]
    end
  rescue
    error ->
      [Message.error_result(Exception.message(error), error_struct: error)]
  catch
    :exit, reason ->
      [Message.error_result("Claude CLI task exited: #{inspect(reason)}", error_struct: reason)]
  end

  defp next([]), do: {:halt, []}
  defp next([message | rest]), do: {[message], rest}

  defp decode_stdout(stdout) when is_binary(stdout) do
    stdout
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case decode_line(line) do
        {:ok, message} -> [message]
        :ignore -> []
        {:error, reason} -> [Message.error_result("Failed to decode Claude CLI output: #{inspect(reason)}")]
      end
    end)
  end

  defp ensure_result(messages) do
    if Enum.any?(messages, &(&1.type == :result)) do
      messages
    else
      messages ++ [Message.error_result("Claude CLI completed without a result frame")]
    end
  end

  @doc false
  def __decode_line__(line), do: decode_line(line)

  defp decode_line(line) when is_binary(line) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" ->
        :ignore

      not String.starts_with?(trimmed, "{") ->
        :ignore

      true ->
        with {:ok, raw} when is_map(raw) <- Jason.decode(trimmed) do
          {:ok, message_from_raw(raw)}
        end
    end
  end

  defp message_from_raw(%{"type" => "system"} = raw) do
    %Message{type: :system, subtype: safe_subtype(:system, raw["subtype"]), data: raw, raw: raw}
  end

  defp message_from_raw(%{"type" => "assistant"} = raw) do
    %Message{
      type: :assistant,
      subtype: nil,
      data: %{
        message: raw["message"],
        session_id: raw["session_id"],
        parent_tool_use_id: raw["parent_tool_use_id"]
      },
      raw: raw
    }
  end

  defp message_from_raw(%{"type" => "user"} = raw) do
    %Message{
      type: :user,
      subtype: nil,
      data: %{
        message: raw["message"],
        session_id: raw["session_id"],
        parent_tool_use_id: raw["parent_tool_use_id"],
        tool_use_result: raw["tool_use_result"]
      },
      raw: raw
    }
  end

  defp message_from_raw(%{"type" => "result"} = raw) do
    %Message{type: :result, subtype: safe_subtype(:result, raw["subtype"]), data: raw, raw: raw}
  end

  defp message_from_raw(%{"type" => "stream_event"} = raw) do
    %Message{
      type: :stream_event,
      subtype: nil,
      data: %{
        uuid: raw["uuid"],
        session_id: raw["session_id"],
        event: raw["event"] || %{},
        parent_tool_use_id: raw["parent_tool_use_id"]
      },
      raw: raw
    }
  end

  defp message_from_raw(%{"type" => "rate_limit_event"} = raw) do
    %Message{type: :rate_limit_event, subtype: nil, data: raw, raw: raw}
  end

  defp message_from_raw(%{"type" => type} = raw) when is_binary(type) do
    %Message{type: type, subtype: nil, data: raw, raw: raw}
  end

  defp message_from_raw(raw), do: %Message{type: :unknown, subtype: nil, data: raw, raw: raw}

  defp safe_subtype(:result, "success"), do: :success
  defp safe_subtype(:result, "error_max_turns"), do: :error_max_turns
  defp safe_subtype(:result, "error_during_execution"), do: :error_during_execution
  defp safe_subtype(:system, "init"), do: :init
  defp safe_subtype(:system, "task_started"), do: :task_started
  defp safe_subtype(:system, "task_progress"), do: :task_progress
  defp safe_subtype(:system, "task_notification"), do: :task_notification
  defp safe_subtype(_type, subtype) when is_binary(subtype), do: subtype
  defp safe_subtype(_type, _subtype), do: nil

  defp env_list(env) when is_map(env) do
    env
    |> Enum.map(fn {key, value} -> {to_string(key), to_string(value)} end)
    |> Enum.reject(fn {_key, value} -> value == "" end)
  end

  defp env_list(_env), do: []

  defp maybe_put_cmd_opt(opts, _key, nil), do: opts
  defp maybe_put_cmd_opt(opts, _key, []), do: opts
  defp maybe_put_cmd_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp shell_join(args), do: Enum.map_join(args, " ", &shell_escape/1)

  defp shell_escape(value) do
    value
    |> to_string()
    |> String.replace("'", "'\"'\"'")
    |> then(&"'#{&1}'")
  end
end
