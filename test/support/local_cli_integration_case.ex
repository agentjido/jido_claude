defmodule Jido.Claude.LocalCLIIntegrationCase do
  @moduledoc false

  use ExUnit.CaseTemplate

  @env_loaded_key {__MODULE__, :env_loaded}
  @required_help_tokens ["--output-format", "stream-json"]

  using do
    quote do
      import Jido.Claude.LocalCLIIntegrationCase

      @moduletag :integration
      @moduletag timeout: 180_000
    end
  end

  def skip_reason do
    ensure_env_loaded()

    cli_skip_reason() ||
      compatibility_skip_reason()
  end

  setup _tags do
    ensure_env_loaded()

    {:ok,
     prompt: live_prompt(),
     cwd: live_cwd(),
     model: env_value("JIDO_CLAUDE_LIVE_MODEL"),
     max_turns: env_integer("JIDO_CLAUDE_LIVE_MAX_TURNS", 1),
     timeout_ms: env_integer("JIDO_CLAUDE_LIVE_TIMEOUT_MS", 180_000),
     require_success?: truthy?(System.get_env("JIDO_CLAUDE_REQUIRE_SUCCESS"))}
  end

  def live_prompt do
    env_value("JIDO_CLAUDE_LIVE_PROMPT") || "Reply with exactly one word: READY"
  end

  def live_cwd do
    env_value("JIDO_CLAUDE_LIVE_CWD") || File.cwd!()
  end

  defp cli_skip_reason do
    case System.find_executable("claude") do
      nil -> "Claude CLI is not available in PATH."
      _path -> nil
    end
  end

  defp compatibility_skip_reason do
    case System.find_executable("claude") do
      nil ->
        nil

      program ->
        {output, exit_status} = System.cmd(program, ["--help"], stderr_to_stdout: true)

        cond do
          exit_status != 0 ->
            "Unable to read `claude --help` for integration checks."

          true ->
            missing = Enum.reject(@required_help_tokens, &String.contains?(output, &1))

            case missing do
              [] -> nil
              _ -> "Installed Claude CLI is missing required help tokens: #{Enum.join(missing, ", ")}"
            end
        end
    end
  end

  defp env_integer(name, default) do
    case env_value(name) do
      nil ->
        default

      value ->
        case Integer.parse(value) do
          {parsed, ""} -> parsed
          _ -> default
        end
    end
  end

  defp env_value(name) do
    case System.get_env(name) do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      _ ->
        nil
    end
  end

  defp truthy?("true"), do: true
  defp truthy?("1"), do: true
  defp truthy?("yes"), do: true
  defp truthy?(_), do: false

  defp ensure_env_loaded do
    case :persistent_term.get(@env_loaded_key, false) do
      true ->
        :ok

      false ->
        maybe_load_dotenv()
        :persistent_term.put(@env_loaded_key, true)
        :ok
    end
  end

  defp maybe_load_dotenv do
    if File.exists?(".env") do
      ".env"
      |> File.stream!()
      |> Enum.each(&load_env_line/1)
    end
  end

  defp load_env_line(line) do
    line = String.trim(line)

    cond do
      line == "" ->
        :ok

      String.starts_with?(line, "#") ->
        :ok

      true ->
        case Regex.run(~r/^(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$/, line) do
          [_, key, raw_value] ->
            if System.get_env(key) in [nil, ""] do
              System.put_env(key, normalize_env_value(raw_value))
            end

          _ ->
            :ok
        end
    end
  end

  defp normalize_env_value(raw_value) do
    value = String.trim(raw_value)

    cond do
      String.starts_with?(value, "\"") and String.ends_with?(value, "\"") ->
        value
        |> String.trim_leading("\"")
        |> String.trim_trailing("\"")

      String.starts_with?(value, "'") and String.ends_with?(value, "'") ->
        value
        |> String.trim_leading("'")
        |> String.trim_trailing("'")

      true ->
        value
    end
  end
end
