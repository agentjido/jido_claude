defmodule Jido.Claude.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/agentjido/jido_claude"
  @description "Claude Code integration for the Jido Agent framework"

  def project do
    [
      app: :jido_claude,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),

      # Documentation
      name: "Jido Claude",
      description: @description,
      source_url: @source_url,
      homepage_url: @source_url,
      package: package(),
      docs: docs(),

      # Test Coverage
      test_coverage: [
        tool: ExCoveralls,
        summary: [threshold: 90]
      ],

      # Dialyzer
      dialyzer: [
        plt_local_path: "priv/plts/project.plt",
        plt_core_path: "priv/plts/core.plt",
        plt_add_apps: [:mix]
      ]
    ]
  end

  def cli do
    [
      preferred_envs: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test,
        "coveralls.github": :test
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps, do: runtime_deps() ++ dev_test_deps()

  defp runtime_deps do
    [
      {:jido, "~> 2.0.0-rc.5"},
      {:claude_agent_sdk, "~> 0.14"},
      harness_dep(),
      shell_dep(),
      {:sprites, git: "https://github.com/mikehostetler/sprites-ex.git", override: true},
      {:jason, "~> 1.4"},
      {:zoi, "~> 0.17"},
      {:splode, ">= 0.2.9 and < 0.4.0", override: true},
      {:uniq, "~> 0.6"}
    ]
  end

  defp harness_dep do
    if File.dir?("../jido_harness") do
      {:jido_harness, "~> 0.1", path: "../jido_harness", override: true}
    else
      {:jido_harness, "~> 0.1"}
    end
  end

  defp shell_dep do
    if File.dir?("../jido_shell") do
      {:jido_shell, path: "../jido_shell", override: true}
    else
      {:jido_shell, github: "agentjido/jido_shell", override: true}
    end
  end

  defp dev_test_deps do
    [
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:doctor, "~> 0.21", only: :dev, runtime: false},
      {:excoveralls, "~> 0.18", only: [:dev, :test]},
      {:git_hooks, "~> 0.8", only: [:dev, :test], runtime: false},
      {:git_ops, "~> 2.9", only: :dev, runtime: false},
      {:mimic, "~> 2.0", only: :test},
      {:stream_data, "~> 1.0", only: [:dev, :test]}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "git_hooks.install"],
      test: "test --exclude flaky",
      q: ["quality"],
      quality: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "credo --min-priority higher",
        "dialyzer",
        "doctor --raise"
      ],
      docs: "docs -f html"
    ]
  end

  defp package do
    [
      files: ["config", "lib", "mix.exs", "README.md", "LICENSE", "CHANGELOG.md", "usage-rules.md"],
      maintainers: ["Mike Hostetler"],
      licenses: ["Apache-2.0"],
      links: %{
        "Changelog" => "https://hexdocs.pm/jido_claude/changelog.html",
        "Discord" => "https://agentjido.xyz/discord",
        "Documentation" => "https://hexdocs.pm/jido_claude",
        "GitHub" => @source_url,
        "Website" => "https://agentjido.xyz"
      }
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: [
        "README.md",
        "CHANGELOG.md",
        "CONTRIBUTING.md"
      ],
      groups_for_modules: [
        Core: [
          Jido.Claude,
          Jido.Claude.ClaudeSessionAgent,
          Jido.Claude.Signals
        ],
        Actions: [
          Jido.Claude.Actions.StartSession,
          Jido.Claude.Actions.HandleMessage,
          Jido.Claude.Actions.CancelSession
        ],
        "Parent Integration": [
          Jido.Claude.Parent.SessionRegistry,
          Jido.Claude.Parent.SpawnSession,
          Jido.Claude.Parent.HandleSessionEvent,
          Jido.Claude.Parent.CancelSession
        ]
      ]
    ]
  end
end
