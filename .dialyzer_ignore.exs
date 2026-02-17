[
  # Mix task callback and Mix.shell/0 warnings - these are false positives
  # because Dialyzer cannot find Mix module specs at compile time
  {"lib/mix/tasks/jido_claude.ex", :callback_info_missing},
  {"lib/mix/tasks/jido_claude.ex", :unknown_function},
  # Jido.Agent macro currently emits plugin_specs specs that are too broad for
  # Dialyzer's inferred literal plugin list typing.
  {"lib/jido_claude/claude_session_agent.ex", :invalid_contract}
]
