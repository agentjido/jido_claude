defmodule JidoClaude.RuntimeConfig do
  @moduledoc false

  @default_model "sonnet"
  @default_settings_path "~/.claude/settings.json"
  @known_env_keys [
    "ANTHROPIC_API_KEY",
    "ANTHROPIC_AUTH_TOKEN",
    "CLAUDE_CODE_API_KEY",
    "ANTHROPIC_BASE_URL",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL",
    "ANTHROPIC_DEFAULT_SONNET_MODEL",
    "ANTHROPIC_DEFAULT_OPUS_MODEL",
    "API_TIMEOUT_MS",
    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC",
    "CLAUDE_AGENT_OAUTH_TOKEN"
  ]

  @required_auth_keys [
    "ANTHROPIC_AUTH_TOKEN",
    "ANTHROPIC_API_KEY",
    "CLAUDE_CODE_API_KEY"
  ]

  @spec default_model() :: String.t()
  def default_model do
    app_default = Application.get_env(:jido_claude, :default_model)
    env_default = System.get_env("JIDO_CLAUDE_DEFAULT_MODEL")

    cond do
      valid_string?(app_default) -> String.trim(app_default)
      valid_string?(env_default) -> String.trim(env_default)
      true -> @default_model
    end
  end

  @spec runtime_env_overrides() :: %{optional(String.t()) => String.t()}
  def runtime_env_overrides do
    settings_env = settings_env_overrides()
    system_env = system_env_overrides(settings_env)

    settings_env
    |> Map.merge(system_env)
    |> Map.merge(app_env_overrides())
  end

  @spec merge_runtime_env(map() | keyword() | nil) :: %{optional(String.t()) => String.t()}
  def merge_runtime_env(env_overrides) do
    runtime_env_overrides()
    |> Map.merge(normalize_env_map(env_overrides))
  end

  @doc """
  Validate strict Claude auth/base-url runtime contract.
  """
  @spec validate_auth_contract!() :: :ok | no_return()
  def validate_auth_contract! do
    require_env!(
      "ANTHROPIC_BASE_URL",
      "ANTHROPIC_BASE_URL environment variable not set"
    )

    require_any_env!(
      @required_auth_keys,
      "One of ANTHROPIC_AUTH_TOKEN, ANTHROPIC_API_KEY, or CLAUDE_CODE_API_KEY must be set"
    )

    :ok
  end

  defp settings_env_overrides do
    with {:ok, settings} <- read_settings(),
         %{} = env <- Map.get(settings, "env") do
      normalize_env_map(env)
    else
      _ -> %{}
    end
  end

  defp system_env_overrides(settings_env) when is_map(settings_env) do
    settings_env
    |> Map.keys()
    |> Kernel.++(@known_env_keys)
    |> Enum.uniq()
    |> Enum.reduce(%{}, fn key, acc ->
      case System.get_env(key) do
        value when is_binary(value) and value != "" -> Map.put(acc, key, value)
        _ -> acc
      end
    end)
  end

  defp app_env_overrides do
    :jido_claude
    |> Application.get_env(:env_overrides, %{})
    |> normalize_env_map()
  end

  defp read_settings do
    path =
      :jido_claude
      |> Application.get_env(:settings_path, nil)
      |> case do
        value when is_binary(value) and value != "" -> value
        _ -> System.get_env("JIDO_CLAUDE_SETTINGS_PATH") || @default_settings_path
      end
      |> Path.expand()

    with {:ok, content} <- File.read(path),
         {:ok, decoded} <- Jason.decode(content),
         %{} = map <- decoded do
      {:ok, map}
    else
      _ -> {:error, :settings_unavailable}
    end
  end

  defp normalize_env_map(map) when is_map(map) do
    Enum.reduce(map, %{}, fn
      {key, value}, acc when is_binary(key) and not is_nil(value) ->
        Map.put(acc, key, to_string(value))

      {key, value}, acc when is_atom(key) and not is_nil(value) ->
        Map.put(acc, Atom.to_string(key), to_string(value))

      _entry, acc ->
        acc
    end)
  end

  defp normalize_env_map(keyword) when is_list(keyword) do
    if Keyword.keyword?(keyword), do: keyword |> Enum.into(%{}) |> normalize_env_map(), else: %{}
  end

  defp normalize_env_map(_), do: %{}

  defp valid_string?(value), do: is_binary(value) and String.trim(value) != ""

  defp require_env!(key, message) do
    if present?(System.get_env(key)), do: :ok, else: raise(message)
  end

  defp require_any_env!(keys, message) when is_list(keys) do
    if Enum.any?(keys, &present?(System.get_env(&1))), do: :ok, else: raise(message)
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: false
end
