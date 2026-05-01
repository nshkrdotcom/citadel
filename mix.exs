defmodule Citadel.Workspace.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/nshkrdotcom/citadel"

  def project do
    [
      app: :citadel_workspace,
      version: @version,
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      blitz_workspace: blitz_workspace(),
      dialyzer: [plt_add_apps: [:mix]],
      docs: docs(),
      source_url: @source_url,
      name: "Citadel Workspace",
      description: "Tooling root for the Citadel non-umbrella monorepo"
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:blitz, "~> 0.2.0", runtime: false},
      {:weld, "~> 0.7.2", runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.40.1", only: :dev, runtime: false}
    ]
  end

  def cli do
    [
      preferred_envs: [
        credo: :test,
        dialyzer: :test,
        ci: :test,
        "hardening.infrastructure_faults": :test,
        "hardening.governance": :test,
        "hardening.governance.adversarial": :test,
        "hardening.governance.mutation": :test,
        "lint.packet_seams": :test,
        "lint.strict": :test,
        "static.analysis": :test
      ]
    ]
  end

  defp aliases do
    monorepo_aliases = [
      "monorepo.deps.get": ["blitz.workspace deps_get"],
      "monorepo.format": ["blitz.workspace format"],
      "monorepo.compile": ["blitz.workspace compile"],
      "monorepo.dialyzer": ["blitz.workspace dialyzer"],
      "monorepo.test": ["blitz.workspace test"]
    ]

    mr_aliases = [
      "mr.deps.get": ["monorepo.deps.get"],
      "mr.format": ["monorepo.format"],
      "mr.compile": ["monorepo.compile"],
      "mr.test": ["monorepo.test"]
    ]

    [
      "hardening.governance.adversarial": [
        "cmd --cd core/policy_packs mix hardening.adversarial",
        "cmd --cd core/citadel_governance mix hardening.adversarial"
      ],
      "hardening.governance.mutation": [
        "cmd --cd core/policy_packs mix hardening.mutation",
        "cmd --cd core/citadel_governance mix hardening.mutation"
      ],
      "hardening.governance": [
        "hardening.governance.adversarial",
        "hardening.governance.mutation"
      ],
      "hardening.infrastructure_faults": [
        "cmd ./dev/docker/toxiproxy/run_fault_injection_suite.sh"
      ],
      "lint.strict": ["credo --config-name strict --all"],
      "static.analysis": [
        "lint.packet_seams",
        "lint.strict",
        "cmd --cd surfaces/citadel_domain_surface mix lint.packet_seams",
        "cmd --cd surfaces/citadel_domain_surface mix lint.strict",
        "monorepo.dialyzer"
      ],
      ci: [
        "deps.get",
        "monorepo.deps.get",
        "monorepo.format --check-formatted",
        "monorepo.compile",
        "static.analysis",
        "monorepo.test",
        "weld.verify"
      ],
      "docs.root": ["docs"]
    ] ++ monorepo_aliases ++ mr_aliases
  end

  defp blitz_workspace do
    [
      root: __DIR__,
      projects: workspace_project_globs(),
      isolation: [
        deps_path: true,
        build_path: true,
        lockfile: true,
        hex_home: "_build/hex"
      ],
      parallelism: [
        env: "CITADEL_MONOREPO_MAX_CONCURRENCY",
        multiplier: :auto,
        base: [
          deps_get: 4,
          format: 4,
          compile: 4,
          test: 4,
          dialyzer: 4
        ],
        overrides: []
      ],
      tasks: [
        deps_get: [args: ["deps.get"], preflight?: false],
        format: [args: ["format"]],
        compile: [args: ["compile", "--warnings-as-errors"]],
        dialyzer: [
          args: ["dialyzer", "--format", "short"],
          mix_env: "test"
        ],
        test: [args: ["test"], mix_env: "test", color: true]
      ]
    ]
  end

  defp docs do
    [
      main: "readme",
      name: "Citadel Workspace",
      logo: "assets/citadel.svg",
      assets: %{"assets" => "assets"},
      source_ref: "v#{@version}",
      source_url: @source_url,
      homepage_url: @source_url,
      extras: [
        "README.md",
        "docs/README.md",
        "docs/workspace_topology.md",
        "docs/publication.md",
        "docs/shared_contract_dependency_strategy.md",
        "CHANGELOG.md",
        "LICENSE"
      ],
      groups_for_extras: [
        Overview: ["README.md", "docs/README.md"],
        Architecture: ["docs/workspace_topology.md", "docs/publication.md"],
        Contracts: ["docs/shared_contract_dependency_strategy.md"],
        Project: ["CHANGELOG.md", "LICENSE"]
      ]
    ]
  end

  defp workspace_project_globs, do: [".", "core/*", "bridges/*", "apps/*", "surfaces/*"]
end
