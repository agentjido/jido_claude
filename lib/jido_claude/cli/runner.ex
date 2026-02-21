defmodule Jido.Claude.CLI.Runner do
  @moduledoc """
  Run Claude CLI in an existing shell session and parse stream-json output.

  This module does not own shell session lifecycle.
  """

  alias Jido.Claude.CLI.Parser
  alias Jido.Claude.CLI.Runner.Result

  @default_timeout 300_000
  @default_prompt_write_timeout 10_000
  @default_prompt_file "/tmp/jido_claude_prompt.txt"
  @default_heartbeat_interval_ms 5_000

  @doc """
  Executes a Claude CLI prompt inside an existing shell session and returns parsed stream results.
  """
  @spec run_in_shell(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, Result.t()} | {:error, term()}
  def run_in_shell(session_id, cwd, prompt, opts \\ [])
      when is_binary(session_id) and is_binary(cwd) and is_binary(prompt) and is_list(opts) do
    shell_agent_mod = Keyword.get(opts, :shell_agent_mod, Jido.Shell.Agent)
    shell_session_server_mod = Keyword.get(opts, :shell_session_server_mod, Jido.Shell.ShellSessionServer)
    stream_json_mod = Keyword.get(opts, :stream_json_mod, default_stream_json_mod())
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    prompt_write_timeout = Keyword.get(opts, :prompt_write_timeout, @default_prompt_write_timeout)
    prompt_file = Keyword.get(opts, :prompt_file, @default_prompt_file)
    heartbeat_interval_ms = Keyword.get(opts, :heartbeat_interval_ms, @default_heartbeat_interval_ms)

    with :ok <- write_prompt(shell_agent_mod, session_id, cwd, prompt_file, prompt, prompt_write_timeout),
         {:ok, output, events} <-
           run_stream_json(
             stream_json_mod,
             shell_agent_mod,
             shell_session_server_mod,
             session_id,
             cwd,
             build_command(prompt_file, opts),
             timeout: timeout,
             heartbeat_interval_ms: heartbeat_interval_ms,
             fallback_eligible?: Keyword.get(opts, :fallback_eligible?, &default_fallback_eligible?/1),
             on_mode: Keyword.get(opts, :on_mode),
             on_event: Keyword.get(opts, :on_event),
             on_raw_line: Keyword.get(opts, :on_raw_line),
             on_heartbeat: Keyword.get(opts, :on_heartbeat)
           ),
         {:ok, result} <-
           Result.new(%{
             raw_output: output || "",
             events: events || [],
             result_text: Parser.extract_result_text(events || [], output),
             status: :ok,
             error: nil,
             metadata: Parser.extract_metadata(events || [])
           }) do
      {:ok, result}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp run_stream_json(
         stream_json_mod,
         shell_agent_mod,
         session_server_mod,
         session_id,
         cwd,
         command,
         opts
       ) do
    if is_atom(stream_json_mod) and function_exported?(stream_json_mod, :run, 6) do
      apply(stream_json_mod, :run, [shell_agent_mod, session_server_mod, session_id, cwd, command, opts])
    else
      run_stream_json_compat(
        shell_agent_mod,
        session_server_mod,
        session_id,
        cwd,
        command,
        opts
      )
    end
  end

  defp write_prompt(shell_agent_mod, session_id, cwd, prompt_file, prompt, timeout) do
    escaped_prompt_file = escape_path(prompt_file)
    write_cmd = "cat > #{escaped_prompt_file} << 'JIDO_PROMPT_EOF'\n#{prompt}\nJIDO_PROMPT_EOF"

    case run_in_dir(shell_agent_mod, session_id, cwd, write_cmd, timeout: timeout) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:prompt_write_failed, reason}}
    end
  end

  defp build_command(prompt_file, opts) do
    include_partial_messages? = Keyword.get(opts, :include_partial_messages, true)
    verbose? = Keyword.get(opts, :verbose, true)
    model = Keyword.get(opts, :model)
    max_turns = Keyword.get(opts, :max_turns)
    cli_args = Keyword.get(opts, :cli_args, [])
    escaped_prompt_file = escape_path(prompt_file)

    "claude -p --output-format stream-json" <>
      maybe_flag(include_partial_messages?, " --include-partial-messages") <>
      maybe_flag(verbose?, " --verbose") <>
      maybe_option(model, " --model ") <>
      maybe_option(max_turns, " --max-turns ") <>
      maybe_cli_args(cli_args) <>
      " \"$(cat #{escaped_prompt_file})\""
  end

  defp maybe_flag(true, flag), do: flag
  defp maybe_flag(_, _flag), do: ""

  defp maybe_option(nil, _prefix), do: ""

  defp maybe_option(value, prefix) do
    prefix <> shell_escape(value)
  end

  defp maybe_cli_args(values) when is_list(values) do
    values
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map_join("", fn arg -> " " <> shell_escape(arg) end)
  end

  defp maybe_cli_args(_), do: ""

  defp shell_escape(value) do
    value
    |> to_string()
    |> String.replace("'", "'\"'\"'")
    |> then(&"'#{&1}'")
  end

  defp default_fallback_eligible?(:unsupported_shell_session_server), do: true
  defp default_fallback_eligible?(%Jido.Shell.Error{code: {:session, :not_found}}), do: true
  defp default_fallback_eligible?(_), do: false

  defp default_stream_json_mod do
    if Code.ensure_loaded?(Jido.Shell.StreamJson) and function_exported?(Jido.Shell.StreamJson, :run, 6) do
      Jido.Shell.StreamJson
    else
      nil
    end
  end

  defp run(shell_agent_mod, session_id, command, opts)
       when is_atom(shell_agent_mod) and is_binary(session_id) and is_binary(command) do
    timeout = Keyword.get(opts, :timeout, 60_000)

    case shell_agent_mod.run(session_id, command, timeout: timeout) do
      {:ok, output} -> {:ok, String.trim(output)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp run_in_dir(shell_agent_mod, session_id, cwd, command, opts)
       when is_atom(shell_agent_mod) and is_binary(session_id) and is_binary(cwd) and
              is_binary(command) do
    wrapped = "cd #{escape_path(cwd)} && #{command}"
    run(shell_agent_mod, session_id, wrapped, opts)
  end

  defp escape_path(path) when is_binary(path) do
    "'#{String.replace(path, "'", "'\\''")}'"
  end

  defp run_stream_json_compat(
         shell_agent_mod,
         session_server_mod,
         session_id,
         cwd,
         command,
         opts
       ) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    heartbeat_interval_ms = Keyword.get(opts, :heartbeat_interval_ms, @default_heartbeat_interval_ms)

    on_mode = Keyword.get(opts, :on_mode)
    on_event = Keyword.get(opts, :on_event)
    on_raw_line = Keyword.get(opts, :on_raw_line)
    on_heartbeat = Keyword.get(opts, :on_heartbeat)

    fallback_eligible? =
      case Keyword.get(opts, :fallback_eligible?) do
        fun when is_function(fun, 1) -> fun
        _ -> &default_fallback_eligible?/1
      end

    safe_callback(on_mode, "session_server_stream")

    case run_streaming_via_session_server(
           session_server_mod,
           session_id,
           cwd,
           command,
           timeout,
           heartbeat_interval_ms,
           on_event,
           on_raw_line,
           on_heartbeat
         ) do
      {:ok, _output, _events} = ok ->
        ok

      {:error, reason} ->
        if safe_fallback_eligible?(fallback_eligible?, reason) do
          safe_callback(on_mode, "shell_agent_fallback")

          with {:ok, output} <- run_in_dir(shell_agent_mod, session_id, cwd, command, timeout: timeout) do
            events = parse_all_stream_lines(output, on_event, on_raw_line)
            {:ok, output, events}
          end
        else
          {:error, reason}
        end
    end
  end

  defp run_streaming_via_session_server(
         session_server_mod,
         session_id,
         cwd,
         command,
         timeout,
         heartbeat_interval_ms,
         on_event,
         on_raw_line,
         on_heartbeat
       ) do
    wrapped = "cd #{escape_path(cwd)} && #{command}"

    with :ok <- ensure_session_server_api(session_server_mod),
         {:ok, :subscribed} <- session_server_mod.subscribe(session_id, self()) do
      try do
        drain_shell_events(session_id)
        deadline_ms = monotonic_ms() + timeout

        case session_server_mod.run_command(session_id, wrapped, execution_context: %{max_runtime_ms: timeout}) do
          {:ok, :accepted} ->
            collect_stream_output(
              session_id,
              deadline_ms,
              heartbeat_interval_ms,
              on_event,
              on_raw_line,
              on_heartbeat,
              "",
              [],
              [],
              false,
              monotonic_ms()
            )

          {:error, reason} ->
            {:error, reason}
        end
      after
        _ = session_server_mod.unsubscribe(session_id, self())
      end
    end
  end

  defp ensure_session_server_api(mod) when is_atom(mod) do
    if function_exported?(mod, :subscribe, 2) and
         function_exported?(mod, :unsubscribe, 2) and
         function_exported?(mod, :run_command, 3) do
      :ok
    else
      {:error, :unsupported_shell_session_server}
    end
  end

  defp safe_fallback_eligible?(fun, reason) when is_function(fun, 1) do
    fun.(reason) == true
  rescue
    _ -> false
  end

  defp collect_stream_output(
         session_id,
         deadline_ms,
         heartbeat_interval_ms,
         on_event,
         on_raw_line,
         on_heartbeat,
         line_buffer,
         output_acc,
         event_acc,
         started?,
         last_event_ms
       ) do
    now = monotonic_ms()
    remaining = deadline_ms - now

    if remaining <= 0 do
      {:error, :timeout}
    else
      receive do
        {:jido_shell_session, ^session_id, {:command_started, _line}} ->
          collect_stream_output(
            session_id,
            deadline_ms,
            heartbeat_interval_ms,
            on_event,
            on_raw_line,
            on_heartbeat,
            line_buffer,
            output_acc,
            event_acc,
            true,
            last_event_ms
          )

        {:jido_shell_session, ^session_id, {:output, chunk}} ->
          {next_buffer, parsed_events, parsed_any?} =
            consume_stream_chunk(line_buffer, chunk, on_event, on_raw_line)

          collect_stream_output(
            session_id,
            deadline_ms,
            heartbeat_interval_ms,
            on_event,
            on_raw_line,
            on_heartbeat,
            next_buffer,
            [chunk | output_acc],
            Enum.reverse(parsed_events) ++ event_acc,
            started?,
            if(parsed_any?, do: monotonic_ms(), else: last_event_ms)
          )

        {:jido_shell_session, ^session_id, {:cwd_changed, _}} ->
          collect_stream_output(
            session_id,
            deadline_ms,
            heartbeat_interval_ms,
            on_event,
            on_raw_line,
            on_heartbeat,
            line_buffer,
            output_acc,
            event_acc,
            started?,
            last_event_ms
          )

        {:jido_shell_session, ^session_id, :command_done} ->
          {trailing_events, trailing_any?} = parse_tail_buffer(line_buffer, on_event, on_raw_line)
          output = output_acc |> Enum.reverse() |> Enum.join() |> String.trim()
          events = Enum.reverse(Enum.reverse(trailing_events) ++ event_acc)
          _ = if trailing_any?, do: monotonic_ms(), else: last_event_ms
          {:ok, output, events}

        {:jido_shell_session, ^session_id, {:error, reason}} ->
          {:error, reason}

        {:jido_shell_session, ^session_id, :command_cancelled} ->
          {:error, :cancelled}

        {:jido_shell_session, ^session_id, {:command_crashed, reason}} ->
          {:error, {:command_crashed, reason}}

        {:jido_shell_session, ^session_id, _event} when not started? ->
          collect_stream_output(
            session_id,
            deadline_ms,
            heartbeat_interval_ms,
            on_event,
            on_raw_line,
            on_heartbeat,
            line_buffer,
            output_acc,
            event_acc,
            started?,
            last_event_ms
          )
      after
        min(heartbeat_interval_ms, remaining) ->
          idle_ms = monotonic_ms() - last_event_ms

          if idle_ms >= heartbeat_interval_ms do
            safe_callback(on_heartbeat, idle_ms)
          end

          collect_stream_output(
            session_id,
            deadline_ms,
            heartbeat_interval_ms,
            on_event,
            on_raw_line,
            on_heartbeat,
            line_buffer,
            output_acc,
            event_acc,
            started?,
            last_event_ms
          )
      end
    end
  end

  defp consume_stream_chunk(buffer, chunk, on_event, on_raw_line) do
    {next_buffer, lines} = split_complete_lines(buffer <> chunk)

    {events, parsed_any?} =
      Enum.reduce(lines, {[], false}, fn line, {acc, any?} ->
        case parse_stream_line(line) do
          {:event, event} ->
            safe_callback(on_event, event)
            {[event | acc], true}

          {:raw, raw_line} ->
            safe_callback(on_raw_line, raw_line)
            {acc, any?}

          :empty ->
            {acc, any?}
        end
      end)

    {next_buffer, Enum.reverse(events), parsed_any?}
  end

  defp parse_tail_buffer("", _on_event, _on_raw_line), do: {[], false}

  defp parse_tail_buffer(buffer, on_event, on_raw_line) do
    case parse_stream_line(buffer) do
      {:event, event} ->
        safe_callback(on_event, event)
        {[event], true}

      {:raw, raw_line} ->
        safe_callback(on_raw_line, raw_line)
        {[], false}

      :empty ->
        {[], false}
    end
  end

  defp parse_all_stream_lines(output, on_event, on_raw_line) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reduce([], fn line, acc ->
      case parse_stream_line(line) do
        {:event, event} ->
          safe_callback(on_event, event)
          [event | acc]

        {:raw, raw_line} ->
          safe_callback(on_raw_line, raw_line)
          acc

        :empty ->
          acc
      end
    end)
    |> Enum.reverse()
  end

  defp split_complete_lines(content) do
    lines = String.split(content, "\n", trim: false)

    case Enum.reverse(lines) do
      [tail | rev_complete] -> {tail, Enum.reverse(rev_complete)}
      [] -> {"", []}
    end
  end

  defp parse_stream_line(line) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" ->
        :empty

      true ->
        case Jason.decode(trimmed) do
          {:ok, event} when is_map(event) -> {:event, event}
          _ -> {:raw, trimmed}
        end
    end
  end

  defp safe_callback(fun, value) when is_function(fun, 1) do
    _ = fun.(value)
    :ok
  rescue
    _ -> :ok
  end

  defp safe_callback(_fun, _value), do: :ok

  defp drain_shell_events(session_id) do
    receive do
      {:jido_shell_session, ^session_id, _event} ->
        drain_shell_events(session_id)
    after
      0 ->
        :ok
    end
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
