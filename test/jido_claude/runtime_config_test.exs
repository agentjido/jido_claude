defmodule JidoClaude.RuntimeConfigTest do
  use ExUnit.Case, async: false

  alias JidoClaude.RuntimeConfig

  @env_keys [
    "JIDO_CLAUDE_SETTINGS_PATH",
    "JIDO_CLAUDE_DEFAULT_MODEL",
    "ANTHROPIC_BASE_URL",
    "ANTHROPIC_DEFAULT_SONNET_MODEL"
  ]

  setup do
    old_env = Map.new(@env_keys, fn key -> {key, System.get_env(key)} end)
    old_default_model = Application.get_env(:jido_claude, :default_model)
    old_env_overrides = Application.get_env(:jido_claude, :env_overrides)

    on_exit(fn ->
      Enum.each(old_env, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      if is_nil(old_default_model) do
        Application.delete_env(:jido_claude, :default_model)
      else
        Application.put_env(:jido_claude, :default_model, old_default_model)
      end

      if is_nil(old_env_overrides) do
        Application.delete_env(:jido_claude, :env_overrides)
      else
        Application.put_env(:jido_claude, :env_overrides, old_env_overrides)
      end
    end)

    :ok
  end

  test "default_model/0 resolves from env before fallback" do
    System.put_env("JIDO_CLAUDE_DEFAULT_MODEL", "glm-4.7")

    assert RuntimeConfig.default_model() == "glm-4.7"
  end

  test "runtime_env_overrides/0 merges settings env, then process env, then app overrides" do
    settings_path =
      write_settings!(%{"env" => %{"ANTHROPIC_BASE_URL" => "https://settings.z.ai", "API_TIMEOUT_MS" => 3_000_000}})

    System.put_env("JIDO_CLAUDE_SETTINGS_PATH", settings_path)
    System.put_env("ANTHROPIC_BASE_URL", "https://process.z.ai")

    Application.put_env(:jido_claude, :env_overrides, %{
      "ANTHROPIC_BASE_URL" => "https://app.z.ai",
      "ANTHROPIC_DEFAULT_SONNET_MODEL" => "glm-4.7"
    })

    env = RuntimeConfig.runtime_env_overrides()

    assert env["ANTHROPIC_BASE_URL"] == "https://app.z.ai"
    assert env["ANTHROPIC_DEFAULT_SONNET_MODEL"] == "glm-4.7"
    assert env["API_TIMEOUT_MS"] == "3000000"
  end

  test "runtime_env_overrides/0 includes known process env keys even without settings file" do
    System.put_env("JIDO_CLAUDE_SETTINGS_PATH", "/tmp/nonexistent-claude-settings.json")
    System.put_env("ANTHROPIC_BASE_URL", "https://process-only.z.ai")

    env = RuntimeConfig.runtime_env_overrides()

    assert env["ANTHROPIC_BASE_URL"] == "https://process-only.z.ai"
  end

  test "merge_runtime_env/1 lets explicit overrides win" do
    settings_path = write_settings!(%{"env" => %{"ANTHROPIC_BASE_URL" => "https://settings.z.ai"}})
    System.put_env("JIDO_CLAUDE_SETTINGS_PATH", settings_path)

    merged = RuntimeConfig.merge_runtime_env(%{"ANTHROPIC_BASE_URL" => "https://explicit.z.ai"})

    assert merged["ANTHROPIC_BASE_URL"] == "https://explicit.z.ai"
  end

  defp write_settings!(map) do
    dir = Path.join(System.tmp_dir!(), "jido_claude_runtime_config_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "settings.json")
    File.write!(path, Jason.encode!(map))
    path
  end
end
