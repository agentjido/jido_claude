defmodule Jido.Claude.Executor.Shell do
  @moduledoc """
  Executor that runs Claude CLI through `jido_shell` session backends.

  This executor keeps Claude orchestration inside `jido_claude` while delegating
  process lifecycle and backend selection (local/sprite/other) to `jido_shell`.
  """

  @behaviour Jido.Claude.Executor

  alias Jido.Claude.CLI.Parser
  alias Jido.Signal

  require Logger

  @shell_session_module Module.concat([Jido, Shell, ShellSession])
  @shell_session_server_module Module.concat([Jido, Shell, ShellSessionServer])
  @sprite_backend_module Module.concat([Jido, Shell, Backend, Sprite])

  @internal_signal_type "claude.internal.message"
  @signal_source "/claude/executor/shell"

  @default_startup_timeout_ms 30_000
  @default_receive_timeout_ms 300_000

  @impl true
  def start(
        %{
          agent_pid: _agent_pid,
          prompt: _prompt,
          options: _options
        } = args
      ) do
    shell_opts = normalize_map(Map.get(args, :shell, %{}))
    startup_timeout_ms = parse_positive(get_opt(shell_opts, :startup_timeout_ms, @default_startup_timeout_ms))

    parent_pid = self()

    with :ok <- ensure_shell_loaded(),
         {:ok, pid} <- Task.start(fn -> run_worker(parent_pid, args, shell_opts) end),
         {:ok, runner_ref} <- await_start(pid, startup_timeout_ms || @default_startup_timeout_ms) do
      metadata = %{
        shell_session_id: Map.get(runner_ref, :shell_session_id),
        shell_workspace_id: Map.get(runner_ref, :workspace_id),
        shell_backend: Map.get(runner_ref, :backend)
      }

      {:ok, runner_ref, metadata}
    end
  end

  @impl true
  def cancel(%{shell_session_id: session_id, pid: pid}) do
    _ = safe_cancel_shell_command(session_id)
    _ = safe_stop_shell_session(session_id)

    if is_pid(pid) and Process.alive?(pid) do
      Process.exit(pid, :shutdown)
    end

    :ok
  end

  def cancel(%{shell_session_id: session_id}) do
    _ = safe_cancel_shell_command(session_id)
    _ = safe_stop_shell_session(session_id)
    :ok
  end

  def cancel(%{pid: pid}) when is_pid(pid) do
    if Process.alive?(pid) do
      Process.exit(pid, :shutdown)
    end

    :ok
  end

  def cancel(nil), do: :ok
  def cancel(_), do: {:error, :invalid_runner_ref}

  defp run_worker(parent_pid, args, shell_opts) do
    agent_pid = Map.fetch!(args, :agent_pid)
    prompt = Map.fetch!(args, :prompt)
    options = normalize_map(Map.get(args, :options, %{}))
    target = Map.get(args, :target, :shell)
    runtime_execution_context = normalize_map(Map.get(args, :execution_context, %{}))

    command = build_command(prompt, options, shell_opts)

    case start_shell_run(command, agent_pid, options, target, shell_opts, runtime_execution_context) do
      {:ok, state} ->
        send(parent_pid, {:executor_started, self(), runner_ref_from_state(state)})
        stream_loop(state)
        _ = safe_unsubscribe(state.session_id)
        _ = safe_stop_shell_session(state.session_id)

      {:error, reason} ->
        send(parent_pid, {:executor_failed, self(), reason})
        dispatch_executor_error(agent_pid, reason)
    end
  rescue
    error ->
      reason = {:shell_executor_exception, Exception.message(error)}
      agent_pid = Map.get(args, :agent_pid)
      send(parent_pid, {:executor_failed, self(), reason})

      if is_pid(agent_pid) do
        dispatch_executor_error(agent_pid, reason)
      end
  end

  defp start_shell_run(command, agent_pid, options, target, shell_opts, runtime_execution_context) do
    with {:ok, workspace_id} <- resolve_workspace_id(shell_opts),
         session_opts <- build_session_opts(options, target, shell_opts),
         {:ok, session_id} <- apply(shell_session(), :start_with_vfs, [workspace_id, session_opts]) do
      command_opts = [
        execution_context: merge_execution_context(shell_opts, runtime_execution_context)
      ]

      case apply(shell_session_server(), :subscribe, [session_id, self()]) do
        {:ok, :subscribed} ->
          case apply(shell_session_server(), :run_command, [session_id, command, command_opts]) do
            {:ok, :accepted} ->
              {:ok,
               %{
                 session_id: session_id,
                 workspace_id: workspace_id,
                 backend: backend_name(session_opts),
                 agent_pid: agent_pid,
                 command: command,
                 buffer: "",
                 receive_timeout_ms: receive_timeout(shell_opts)
               }}

            {:error, reason} ->
              _ = safe_unsubscribe(session_id)
              _ = safe_stop_shell_session(session_id)
              {:error, {:shell_command_start_failed, reason}}
          end

        {:error, reason} ->
          _ = safe_stop_shell_session(session_id)
          {:error, {:shell_subscribe_failed, reason}}
      end
    end
  end

  defp stream_loop(state) do
    receive do
      {:jido_shell_session, session_id, event} when session_id == state.session_id ->
        case handle_shell_event(event, state) do
          {:continue, updated_state} ->
            stream_loop(updated_state)

          {:stop, updated_state} ->
            flush_buffer(updated_state)
            :ok
        end
    after
      state.receive_timeout_ms ->
        dispatch_executor_error(state.agent_pid, {:shell_stream_timeout, state.session_id, state.receive_timeout_ms})
    end
  end

  defp handle_shell_event({:output, chunk}, state) when is_binary(chunk) do
    {lines, buffer} = split_lines(state.buffer <> chunk)
    Enum.each(lines, &dispatch_stream_line(state.agent_pid, &1))
    {:continue, %{state | buffer: buffer}}
  end

  defp handle_shell_event(:command_done, state), do: {:stop, state}

  defp handle_shell_event(:command_cancelled, state) do
    dispatch_executor_error(state.agent_pid, :command_cancelled)
    {:stop, state}
  end

  defp handle_shell_event({:command_crashed, reason}, state) do
    dispatch_executor_error(state.agent_pid, {:command_crashed, reason})
    {:stop, state}
  end

  defp handle_shell_event({:error, error}, state) do
    dispatch_executor_error(state.agent_pid, {:shell_error, error})
    {:stop, state}
  end

  defp handle_shell_event(_event, state), do: {:continue, state}

  defp flush_buffer(%{buffer: ""}), do: :ok

  defp flush_buffer(%{agent_pid: agent_pid, buffer: buffer}) when is_binary(buffer) do
    trimmed = String.trim(buffer)

    if trimmed != "" do
      dispatch_stream_line(agent_pid, trimmed)
    end

    :ok
  end

  defp dispatch_stream_line(_agent_pid, ""), do: :ok

  defp dispatch_stream_line(agent_pid, line) do
    trimmed = line |> String.trim() |> String.trim_trailing("\r")

    if trimmed != "" do
      case Parser.decode_stream_line(trimmed) do
        {:ok, message} ->
          dispatch_internal_message(agent_pid, message)

        {:error, reason} ->
          dispatch_executor_error(agent_pid, {:invalid_stream_json, reason, trimmed})
      end
    end
  end

  defp dispatch_internal_message(agent_pid, message) do
    signal =
      Signal.new!(%{
        type: @internal_signal_type,
        source: @signal_source,
        data: message
      })

    Jido.Signal.Dispatch.dispatch(signal, {:pid, target: agent_pid})
  end

  defp dispatch_executor_error(agent_pid, reason) do
    Logger.debug("Shell executor error: #{inspect(reason)}")

    dispatch_internal_message(agent_pid, %{
      type: :result,
      subtype: :error_exception,
      data: %{
        error: inspect(reason),
        source: "shell_executor"
      },
      raw: nil
    })
  end

  defp await_start(pid, timeout_ms) when is_pid(pid) and is_integer(timeout_ms) and timeout_ms > 0 do
    ref = Process.monitor(pid)

    receive do
      {:executor_started, ^pid, runner_ref} ->
        Process.demonitor(ref, [:flush])
        {:ok, runner_ref}

      {:executor_failed, ^pid, reason} ->
        Process.demonitor(ref, [:flush])
        {:error, reason}

      {:DOWN, ^ref, :process, ^pid, reason} ->
        {:error, {:shell_executor_crashed, reason}}
    after
      timeout_ms ->
        Process.demonitor(ref, [:flush])

        if Process.alive?(pid) do
          Process.exit(pid, :shutdown)
        end

        {:error, :shell_executor_start_timeout}
    end
  end

  defp runner_ref_from_state(state) do
    %{
      pid: self(),
      shell_session_id: state.session_id,
      workspace_id: state.workspace_id,
      backend: state.backend
    }
  end

  defp resolve_workspace_id(shell_opts) do
    workspace_id = get_opt(shell_opts, :workspace_id, nil)

    cond do
      is_binary(workspace_id) and String.trim(workspace_id) != "" ->
        {:ok, workspace_id}

      is_nil(workspace_id) ->
        {:ok, "claude-shell-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)}

      true ->
        {:error, {:invalid_shell_workspace_id, workspace_id}}
    end
  end

  defp build_session_opts(options, target, shell_opts) do
    session_opts = normalize_keyword(get_opt(shell_opts, :session_opts, []))
    fallback_cwd = get_opt(options, :cwd, nil)
    cwd = get_opt(shell_opts, :cwd, fallback_cwd)
    runtime_env = Jido.Claude.RuntimeConfig.runtime_env_overrides()
    option_env = normalize_env(get_opt(options, :env, %{}))
    shell_env = normalize_env(get_opt(shell_opts, :env, %{}))
    env = runtime_env |> Map.merge(option_env) |> Map.merge(shell_env)
    meta = normalize_map(get_opt(shell_opts, :meta, %{}))
    backend = resolve_backend(shell_opts, target)

    defaults =
      []
      |> maybe_put_kw(:cwd, cwd)
      |> maybe_put_kw(:env, env)
      |> maybe_put_kw(:meta, meta)
      |> maybe_put_kw(:backend, backend)

    Keyword.merge(defaults, session_opts)
  end

  defp resolve_backend(shell_opts, :sprite) do
    case get_opt(shell_opts, :backend, nil) do
      nil ->
        sprite_config = normalize_map(get_opt(shell_opts, :sprite, %{}))
        {@sprite_backend_module, sprite_config}

      backend ->
        backend
    end
  end

  defp resolve_backend(shell_opts, _target), do: get_opt(shell_opts, :backend, nil)

  defp merge_execution_context(shell_opts, runtime_execution_context) do
    shell_context = normalize_map(get_opt(shell_opts, :execution_context, %{}))
    deep_merge(shell_context, runtime_execution_context)
  end

  defp receive_timeout(shell_opts) do
    parse_positive(get_opt(shell_opts, :receive_timeout_ms, @default_receive_timeout_ms)) ||
      @default_receive_timeout_ms
  end

  defp build_command(prompt, options, shell_opts) do
    model = get_opt(options, :model, nil)
    max_turns = parse_positive(get_opt(options, :max_turns, nil))
    skip_permissions = truthy?(get_opt(shell_opts, :skip_permissions, true))
    cli_args = normalize_string_list(get_opt(shell_opts, :cli_args, []))

    args =
      ["claude", "-p", prompt, "--output-format", "stream-json"]
      |> maybe_append_option("--model", model)
      |> maybe_append_option("--max-turns", max_turns)
      |> maybe_append_flag("--dangerously-skip-permissions", skip_permissions)
      |> Kernel.++(cli_args)

    args
    |> Enum.map(&shell_escape/1)
    |> Enum.join(" ")
  end

  defp maybe_append_option(args, _flag, nil), do: args
  defp maybe_append_option(args, flag, value), do: args ++ [flag, to_string(value)]

  defp maybe_append_flag(args, _flag, false), do: args
  defp maybe_append_flag(args, flag, true), do: args ++ [flag]

  defp shell_escape(value) do
    value
    |> to_string()
    |> String.replace("'", "'\"'\"'")
    |> then(&"'#{&1}'")
  end

  defp split_lines(data) when is_binary(data) do
    parts = String.split(data, "\n", trim: false)

    case parts do
      [] ->
        {[], ""}

      [_single] ->
        {[], data}

      _ ->
        buffer = List.last(parts) || ""
        lines = Enum.drop(parts, -1)
        {lines, buffer}
    end
  end

  defp safe_cancel_shell_command(session_id) when is_binary(session_id) do
    if ensure_shell_loaded() == :ok do
      case apply(shell_session_server(), :cancel, [session_id]) do
        {:ok, _} -> :ok
        {:error, _} -> :ok
      end
    else
      :ok
    end
  end

  defp safe_cancel_shell_command(_), do: :ok

  defp safe_unsubscribe(session_id) when is_binary(session_id) do
    if ensure_shell_loaded() == :ok do
      case apply(shell_session_server(), :unsubscribe, [session_id, self()]) do
        {:ok, _} -> :ok
        {:error, _} -> :ok
      end
    else
      :ok
    end
  end

  defp safe_unsubscribe(_), do: :ok

  defp safe_stop_shell_session(session_id) when is_binary(session_id) do
    if ensure_shell_loaded() == :ok do
      case apply(shell_session(), :stop, [session_id]) do
        :ok -> :ok
        {:error, _} -> :ok
      end
    else
      :ok
    end
  end

  defp safe_stop_shell_session(_), do: :ok

  defp backend_name(session_opts) do
    case Keyword.get(session_opts, :backend) do
      {backend_module, _config} when is_atom(backend_module) -> inspect(backend_module)
      backend_module when is_atom(backend_module) -> inspect(backend_module)
      _ -> nil
    end
  end

  defp shell_session, do: @shell_session_module
  defp shell_session_server, do: @shell_session_server_module

  defp ensure_shell_loaded do
    if Code.ensure_loaded?(@shell_session_module) and Code.ensure_loaded?(@shell_session_server_module) do
      :ok
    else
      {:error, {:missing_dependency, :jido_shell}}
    end
  end

  defp maybe_put_kw(opts, _key, nil), do: opts
  defp maybe_put_kw(opts, key, value), do: Keyword.put(opts, key, value)

  defp normalize_map(value) when is_map(value), do: value

  defp normalize_map(value) when is_list(value) do
    if Keyword.keyword?(value) do
      Enum.into(value, %{}, fn {key, val} -> {key, normalize_map(val)} end)
    else
      value
    end
  end

  defp normalize_map(value), do: value

  defp normalize_keyword(value) when is_list(value) do
    if Keyword.keyword?(value) do
      value
    else
      []
    end
  end

  defp normalize_keyword(value) when is_map(value), do: Enum.to_list(value)
  defp normalize_keyword(_value), do: []

  defp normalize_env(env) when is_map(env) do
    Enum.reduce(env, %{}, fn {key, value}, acc ->
      Map.put(acc, to_string(key), to_string(value))
    end)
  end

  defp normalize_env(_), do: %{}

  defp normalize_string_list(value) do
    value
    |> List.wrap()
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?("1"), do: true
  defp truthy?(1), do: true
  defp truthy?(_), do: false

  defp parse_positive(value) when is_integer(value) and value > 0, do: value

  defp parse_positive(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> nil
    end
  end

  defp parse_positive(_), do: nil

  defp get_opt(source, key, default) when is_map(source) do
    case Map.fetch(source, key) do
      {:ok, value} -> value
      :error -> Map.get(source, to_string(key), default)
    end
  end

  defp get_opt(source, key, default) when is_list(source) do
    if Keyword.keyword?(source) do
      case Keyword.fetch(source, key) do
        {:ok, value} -> value
        :error -> Keyword.get(source, to_string(key), default)
      end
    else
      default
    end
  end

  defp get_opt(_source, _key, default), do: default

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      deep_merge(left_value, right_value)
    end)
  end

  defp deep_merge(_left, right), do: right
end
