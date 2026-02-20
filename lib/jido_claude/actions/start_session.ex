defmodule Jido.Claude.Actions.StartSession do
  @moduledoc """
  Start a Claude Code session.

  This action initializes a Claude session by:
  1. Building SDK options from parameters
  2. Resolving an execution target (`:local`, `:shell`, `:sprite`)
  3. Starting the selected executor
  4. Updating agent state to `:running`

  ## Parameters

    * `prompt` - Required. The prompt to send to Claude.
    * `model` - Optional. Model to use ("haiku", "sonnet", "opus"). Default: "sonnet"
    * `max_turns` - Optional. Maximum agentic loop iterations. Default: 25
    * `allowed_tools` - Optional. List of allowed tool names. Default: ["Read", "Glob", "Grep", "Bash"]
    * `cwd` - Optional. Working directory for tools. Default: current directory
    * `system_prompt` - Optional. Custom system prompt.
    * `sdk_timeout_ms` - Optional. SDK-level timeout. Default: 600_000 (10 minutes)
    * `target` - Optional. `:local` (default), `:shell`, or `:sprite`
    * `shell` - Optional. Shell execution settings when using shell-backed targets
    * `execution_context` - Optional. Limits/network policy for shell-backed targets

  ## Example

      cmd(agent, {StartSession, %{
        prompt: "Analyze this codebase",
        model: "sonnet",
        max_turns: 50
      }})

  """

  use Jido.Action,
    name: "claude_start_session",
    description: "Start a Claude Code session",
    schema: [
      prompt: [type: :string, required: true],
      model: [type: :string, default: "sonnet"],
      max_turns: [type: :integer, default: 25],
      allowed_tools: [type: {:list, :string}, default: ["Read", "Glob", "Grep", "Bash"]],
      cwd: [type: :string, default: nil],
      system_prompt: [type: :string, default: nil],
      sdk_timeout_ms: [type: :integer, default: 600_000],
      target: [type: :atom, default: :local],
      shell: [type: :map, default: %{}],
      execution_context: [type: :map, default: %{}]
    ]

  @impl true
  def run(params, context) do
    agent_pid = context[:agent_pid] || self()
    session_id = get_session_id(context)
    target = params[:target] || :local

    options = build_options(params)

    start_args = %{
      agent_pid: agent_pid,
      prompt: params.prompt,
      options: options,
      target: target,
      shell: params[:shell] || %{},
      execution_context: params[:execution_context] || %{}
    }

    with {:ok, executor_module} <- resolve_executor_module(target, context),
         {:ok, runner_ref, executor_meta} <- executor_module.start(start_args) do
      result =
        %{
          status: :running,
          session_id: session_id,
          prompt: params.prompt,
          options: options,
          turns: 0,
          transcript: [],
          execution_target: target,
          executor_module: executor_module,
          runner_ref: runner_ref
        }
        |> merge_executor_meta(executor_meta)

      {:ok, result, []}
    end
  end

  defp get_session_id(context) do
    cond do
      context[:session_id] -> context.session_id
      context[:agent] && context.agent.state[:session_id] -> context.agent.state.session_id
      true -> generate_session_id()
    end
  end

  defp generate_session_id do
    "claude-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
  end

  defp build_options(params) do
    model = params[:model] || Jido.Claude.RuntimeConfig.default_model()

    %{
      model: model,
      max_turns: params.max_turns,
      allowed_tools: params.allowed_tools,
      cwd: params[:cwd] || File.cwd!(),
      system_prompt: params[:system_prompt],
      timeout_ms: params[:sdk_timeout_ms],
      env: Jido.Claude.RuntimeConfig.runtime_env_overrides()
    }
  end

  defp resolve_executor_module(target, context) do
    if context[:executor_module] do
      {:ok, context.executor_module}
    else
      case target do
        :local ->
          {:ok, Application.get_env(:jido_claude, :executor_local_module, Jido.Claude.Executor.Local)}

        :shell ->
          {:ok, Application.get_env(:jido_claude, :executor_shell_module, Jido.Claude.Executor.Shell)}

        :sprite ->
          {:ok, Application.get_env(:jido_claude, :executor_shell_module, Jido.Claude.Executor.Shell)}

        other ->
          {:error, {:unsupported_execution_target, other}}
      end
    end
  end

  defp merge_executor_meta(state, meta) when is_map(meta), do: Map.merge(state, meta)
  defp merge_executor_meta(state, _meta), do: state
end
