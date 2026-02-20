defmodule JidoClaude.Adapter do
  @moduledoc """
  `Jido.Harness.Adapter` implementation for Claude Code.
  """

  @behaviour Jido.Harness.Adapter

  alias ClaudeAgentSDK.Options
  alias Jido.Harness.{Capabilities, Event, RunRequest, RuntimeContract}
  alias JidoClaude.Mapper

  @option_keys [
    :model,
    :max_turns,
    :timeout_ms,
    :system_prompt,
    :allowed_tools,
    :cwd,
    :verbose,
    :include_partial_messages,
    :output_format,
    :env
  ]

  @impl true
  @spec id() :: atom()
  def id, do: :claude

  @impl true
  @spec capabilities() :: map()
  def capabilities do
    %Capabilities{
      streaming?: true,
      tool_calls?: true,
      tool_results?: true,
      thinking?: true,
      cancellation?: false
    }
  end

  @impl true
  @spec run(RunRequest.t(), keyword()) :: {:ok, Enumerable.t()} | {:error, term()}
  def run(%RunRequest{} = request, opts \\ []) when is_list(opts) do
    with {:ok, options} <- build_options(request, opts) do
      stream =
        sdk_module()
        |> apply(:query, [request.prompt, options])
        |> Stream.flat_map(fn message ->
          case mapper_module().map_message(message) do
            {:ok, events} when is_list(events) ->
              events

            {:error, reason} ->
              [mapper_error_event(reason)]
          end
        end)

      {:ok, stream}
    else
      {:error, _} = error ->
        error
    end
  rescue
    e in [ArgumentError] ->
      {:error, {:claude_invalid_request, Exception.message(e)}}
  end

  @impl true
  @spec runtime_contract() :: RuntimeContract.t()
  def runtime_contract do
    RuntimeContract.new!(%{
      provider: :claude,
      host_env_required_any: ["ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY", "CLAUDE_CODE_API_KEY"],
      host_env_required_all: [],
      sprite_env_forward: [
        "ANTHROPIC_BASE_URL",
        "ANTHROPIC_AUTH_TOKEN",
        "ANTHROPIC_API_KEY",
        "CLAUDE_CODE_API_KEY",
        "ANTHROPIC_DEFAULT_HAIKU_MODEL",
        "ANTHROPIC_DEFAULT_SONNET_MODEL",
        "ANTHROPIC_DEFAULT_OPUS_MODEL",
        "GH_TOKEN",
        "GITHUB_TOKEN"
      ],
      sprite_env_injected: %{
        "GH_PROMPT_DISABLED" => "1",
        "GIT_TERMINAL_PROMPT" => "0",
        "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC" => "1",
        "API_TIMEOUT_MS" => "3000000"
      },
      runtime_tools_required: ["claude"],
      compatibility_probes: [
        %{
          "name" => "claude_help_stream_json",
          "command" => "claude --help",
          "expect_all" => ["--output-format", "stream-json"]
        }
      ],
      install_steps: [],
      auth_bootstrap_steps: [],
      triage_command_template:
        "if command -v timeout >/dev/null 2>&1; then timeout 180 claude -p --output-format stream-json --include-partial-messages --no-session-persistence --verbose --dangerously-skip-permissions \"{{prompt}}\"; else claude -p --output-format stream-json --include-partial-messages --no-session-persistence --verbose --dangerously-skip-permissions \"{{prompt}}\"; fi",
      coding_command_template:
        "if command -v timeout >/dev/null 2>&1; then timeout 180 claude -p --output-format stream-json --include-partial-messages --no-session-persistence --verbose --dangerously-skip-permissions \"{{prompt}}\"; else claude -p --output-format stream-json --include-partial-messages --no-session-persistence --verbose --dangerously-skip-permissions \"{{prompt}}\"; fi",
      success_markers: [
        %{"type" => "result", "subtype" => "success", "is_error_false" => true}
      ]
    })
  end

  defp build_options(%RunRequest{} = request, opts) do
    metadata =
      request.metadata
      |> Map.get("claude", Map.get(request.metadata, :claude, %{}))
      |> normalize_map_keys()

    request_attrs =
      %{
        model: request.model,
        max_turns: request.max_turns,
        timeout_ms: request.timeout_ms,
        system_prompt: request.system_prompt,
        allowed_tools: request.allowed_tools,
        cwd: request.cwd
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Enum.into(%{})

    runtime_attrs =
      opts
      |> Keyword.take(@option_keys)
      |> Enum.into(%{})

    attrs =
      request_attrs
      |> Map.merge(metadata)
      |> Map.merge(runtime_attrs)
      |> Map.put_new(:output_format, :stream_json)
      |> Map.put_new(:include_partial_messages, true)

    {:ok, struct(Options, attrs)}
  rescue
    e in [KeyError, ArgumentError] ->
      {:error, {:claude_option_error, Exception.message(e)}}
  end

  defp normalize_map_keys(map) when is_map(map) do
    Enum.reduce(map, %{}, fn
      {key, value}, acc when is_atom(key) ->
        if key in @option_keys, do: Map.put(acc, key, value), else: acc

      {key, value}, acc when is_binary(key) ->
        atom =
          @option_keys
          |> Enum.find(fn item -> Atom.to_string(item) == key end)

        if atom, do: Map.put(acc, atom, value), else: acc

      _, acc ->
        acc
    end)
  end

  defp normalize_map_keys(_), do: %{}

  defp mapper_error_event(reason) do
    Event.new!(%{
      type: :session_failed,
      provider: :claude,
      session_id: nil,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      payload: %{"error" => inspect(reason)},
      raw: reason
    })
  end

  defp mapper_module do
    Application.get_env(:jido_claude, :mapper_module, Mapper)
  end

  defp sdk_module do
    Application.get_env(:jido_claude, :sdk_module, ClaudeAgentSDK)
  end
end
