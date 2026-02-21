# Jido Claude

Claude Code integration for the Jido Agent framework.

## Installation

Add `jido_claude` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:jido_claude, "~> 0.1.0"}
  ]
end
```

## Prerequisites

1. **Claude Code CLI** must be installed and authenticated:
   ```bash
   npm install -g @anthropic-ai/claude-code
   claude  # authenticate via browser
   ```

2. The SDK uses the CLI's stored authentication - no API keys needed in your Elixir app.

## Claude Runtime Env Support

`jido_claude` now forwards Claude runtime env overrides from:

1. `~/.claude/settings.json` (`env` object), then
2. process env vars (which override settings values), then
3. `config :jido_claude, :env_overrides` (highest priority).

This includes ZAI-compatible settings such as:

- `ANTHROPIC_BASE_URL`
- `ANTHROPIC_AUTH_TOKEN`
- `ANTHROPIC_DEFAULT_HAIKU_MODEL`
- `ANTHROPIC_DEFAULT_SONNET_MODEL`
- `ANTHROPIC_DEFAULT_OPUS_MODEL`

You can also set a package-level default model with:

- `JIDO_CLAUDE_DEFAULT_MODEL` or
- `config :jido_claude, :default_model, "..."`

## Architecture

Jido.Claude provides a two-agent pattern for running Claude Code sessions:

```
┌─────────────────────────────────────────┐
│  Parent Agent (Orchestrator)            │
│  - Spawns ClaudeSessionAgent children   │
│  - Receives signals from all sessions   │
│  - Tracks status in sessions registry   │
└─────────────────────────────────────────┘
          │ SpawnAgent
          ▼
┌─────────────────────────────────────────┐
│  ClaudeSessionAgent                     │
│  - Owns single Claude session           │
│  - Runs SDK in background Task          │
│  - Emits turn signals to parent         │
└─────────────────────────────────────────┘
          │ Task
          ▼
┌─────────────────────────────────────────┐
│  StreamRunner                           │
│  - Calls ClaudeAgentSDK.query/3         │
│  - Dispatches messages as signals       │
└─────────────────────────────────────────┘
```

## Usage

### Single Session

```elixir
alias Jido.Claude.ClaudeSessionAgent
alias Jido.Claude.Actions.StartSession

# Start a session agent
{:ok, pid} = Jido.Agent.Server.start_link(
  agent: ClaudeSessionAgent,
  name: {:via, Registry, {MyRegistry, "claude-1"}}
)

# Run a prompt
Jido.Agent.Server.cmd(pid, {StartSession, %{
  prompt: "Analyze this codebase",
  model: "sonnet",
  max_turns: 25
}})
```

### Multi-Session (Parent Agent)

```elixir
defmodule MyOrchestrator do
  use Jido.Agent,
    name: "orchestrator",
    schema: [
      sessions: [type: :map, default: %{}]
    ]

  alias Jido.Claude.Parent.{SpawnSession, HandleSessionEvent, CancelSession}

  def signal_routes do
    [
      {"claude.session.started", {HandleSessionEvent, &extract_params/1}},
      {"claude.session.success", {HandleSessionEvent, &extract_params/1}},
      {"claude.session.error", {HandleSessionEvent, &extract_params/1}}
    ]
  end

  defp extract_params(signal) do
    %{
      session_id: signal.data.session_id,
      event_type: signal.type,
      data: signal.data
    }
  end

  def actions do
    [SpawnSession, CancelSession]
  end
end

# Spawn multiple concurrent sessions
{agent, _} = MyOrchestrator.cmd(agent, {SpawnSession, %{
  session_id: "review-pr-123",
  prompt: "Review PR #123 for security issues"
}})

{agent, _} = MyOrchestrator.cmd(agent, {SpawnSession, %{
  prompt: "Analyze dependencies"  # auto-generates session_id
}})

# Check status
agent.state.sessions
# => %{
#   "review-pr-123" => %{status: :running, turns: 3, ...},
#   "claude-a1b2c3d4" => %{status: :running, turns: 1, ...}
# }

# Cancel a session
{agent, _} = MyOrchestrator.cmd(agent, {CancelSession, %{
  session_id: "review-pr-123"
}})
```

## Signal Types

| Signal | Description |
|--------|-------------|
| `claude.session.started` | Session initialized with model info |
| `claude.turn.text` | Claude's text response |
| `claude.turn.tool_use` | Claude is calling a tool |
| `claude.turn.tool_result` | Tool execution result |
| `claude.session.success` | Session completed successfully |
| `claude.session.error` | Session failed |

## Live Sprite Integration Test

`jido_claude` includes an opt-in live integration test for sprite-backed execution:

```bash
mix test --include integration test/jido_claude/integration/sprite_shell_integration_test.exs
```

The test loads `.env` automatically and looks for:

- `SPRITE_TOKEN` (or `SPRITES_TEST_TOKEN`) - required
- `SPRITE_BASE_URL` (or `SPRITES_TEST_BASE_URL`) - optional
- `JIDO_CLAUDE_SPRITE_NAME` - optional fixed sprite name (otherwise a unique name is generated)
- `JIDO_CLAUDE_REQUIRE_SUCCESS=1` - optional strict mode (fail unless Claude run ends in `:success`)

By default, integration tests are excluded from `mix test`.
If `jido_shell` or `sprites-ex` is unavailable in the test runtime, the integration test is skipped with a clear reason.

## Configuration Options

### StartSession / SpawnSession

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `prompt` | string | required | The prompt to send to Claude |
| `model` | string | default model config or "sonnet" | Claude model/alias (for example: `haiku`, `sonnet`, `opus`, or custom backend alias) |
| `max_turns` | integer | 25 | Maximum agentic loop iterations |
| `allowed_tools` | list | ["Read", "Glob", "Grep", "Bash"] | Tools Claude can use |
| `cwd` | string | current dir | Working directory for tools |
| `system_prompt` | string | nil | Custom system prompt |
| `sdk_timeout_ms` | integer | 600_000 | SDK-level timeout (10 min) |
| `target` | atom | `:local` | Execution target: `:local`, `:shell`, or `:sprite` |
| `shell` | map | `%{}` | Shell executor options (workspace/backend/session options) |
| `execution_context` | map | `%{}` | Per-run limits/network context forwarded to `jido_shell` |
| `meta` | map | %{} | Custom metadata (SpawnSession only) |

Shell-backed runs require adding `jido_shell` to your dependencies. For Sprite execution,
set `target: :sprite` and pass Sprite backend config via `shell`:

```elixir
Jido.Agent.Server.cmd(pid, {StartSession, %{
  prompt: "Analyze this codebase",
  target: :sprite,
  shell: %{
    backend: {Jido.Shell.Backend.Sprite, %{
      sprite_name: "my-sprite",
      token: System.fetch_env!("SPRITES_TOKEN"),
      create: true
    }}
  }
}})
```

## License

Apache 2.0

## Package Purpose

`jido_claude` is the Claude adapter package for `jido_harness`, exposing normalized runs while keeping Claude-specific mapping and runtime contract details isolated.

## Testing Paths

- Unit/contract tests: `mix test`
- Full quality gate: `mix quality`
- Optional live/sprite checks: run tests tagged `:integration` when credentials and CLI are available
