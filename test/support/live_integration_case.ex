defmodule JidoClaude.LiveIntegrationCase do
  @moduledoc false

  use ExUnit.CaseTemplate

  @env_loaded_key {__MODULE__, :env_loaded}
  @shell_session_module Module.concat([Jido, Shell, ShellSession])
  @shell_backend_sprite_module Module.concat([Jido, Shell, Backend, Sprite])

  using do
    quote do
      import JidoClaude.LiveIntegrationCase

      @moduletag :integration
      @moduletag timeout: 240_000
    end
  end

  def skip_reason do
    ensure_env_loaded()

    cond do
      not sprite_token_present?() ->
        "set SPRITE_TOKEN (or SPRITES_TEST_TOKEN) to run sprite integration tests"

      not Code.ensure_loaded?(@shell_session_module) ->
        "jido_shell is required for sprite integration tests"

      not Code.ensure_loaded?(@shell_backend_sprite_module) ->
        "Jido.Shell.Backend.Sprite is not available"

      not Code.ensure_loaded?(Sprites) ->
        "sprites-ex is required for sprite integration tests"

      true ->
        nil
    end
  end

  setup _tags do
    ensure_env_loaded()

    with {:ok, token} <- fetch_sprite_token(),
         :ok <- ensure_shell_started() do
      {:ok,
       sprite_token: token,
       sprite_base_url: sprite_base_url(),
       require_success?: truthy?(System.get_env("JIDO_CLAUDE_REQUIRE_SUCCESS"))}
    else
      {:error, reason} ->
        raise "sprite integration prerequisites failed: #{inspect(reason)}"
    end
  end

  def unique_name(prefix \\ "jido-claude-it") do
    suffix = System.unique_integer([:positive, :monotonic])
    "#{prefix}-#{suffix}"
  end

  def sprite_name do
    System.get_env("JIDO_CLAUDE_SPRITE_NAME") || unique_name("jido-claude")
  end

  def sprite_base_url do
    System.get_env("SPRITES_TEST_BASE_URL") || System.get_env("SPRITE_BASE_URL")
  end

  defp sprite_token_present? do
    case System.get_env("SPRITE_TOKEN") || System.get_env("SPRITES_TEST_TOKEN") do
      token when is_binary(token) -> byte_size(String.trim(token)) > 0
      _ -> false
    end
  end

  defp fetch_sprite_token do
    case System.get_env("SPRITE_TOKEN") || System.get_env("SPRITES_TEST_TOKEN") do
      token when is_binary(token) ->
        if byte_size(String.trim(token)) > 0 do
          {:ok, token}
        else
          {:error, :missing_sprite_token}
        end

      _ ->
        {:error, :missing_sprite_token}
    end
  end

  defp ensure_shell_started do
    case Application.ensure_all_started(:jido_shell) do
      {:ok, _started} -> :ok
      {:error, {:already_started, :jido_shell}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?("1"), do: true
  defp truthy?(1), do: true
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
