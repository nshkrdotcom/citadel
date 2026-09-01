if bootstrap = System.get_env("MIX_WORKSPACE_OPS_BOOTSTRAP"), do: Code.require_file(bootstrap)

defmodule Citadel.Governance.MixProject do
  use Mix.Project

  def project do
    [
      app: :citadel_governance,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      description:
        "Governance values, policy compilation, and durable authority truth for Citadel"
    ]
  end

  def application do
    [
      extra_applications: [:crypto, :ecto_sql, :logger]
    ]
  end

  def cli do
    [preferred_envs: preferred_cli_env()]
  end

  defp deps do
    [
      {:citadel_contract_core, path: "../contract_core"},
      {:citadel_authority_contract, path: "../authority_contract"},
      {:citadel_execution_governance_contract, path: "../execution_governance_contract"},
      {:citadel_observability_contract, path: "../observability_contract"},
      {:citadel_policy_packs, path: "../policy_packs"},
      workspace_dep({:jido_integration_contracts, "~> 0.1.0"}),
      {:ecto_sql, "~> 3.14"},
      {:postgrex, "~> 0.22"},
      {:stream_data, "~> 1.1", only: :test},
      {:muex, "~> 0.6", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp workspace_dep(committed) do
    if function_exported?(MixWorkspaceOpsBootstrap, :dep, 2),
      do: apply(MixWorkspaceOpsBootstrap, :dep, [committed, __DIR__]),
      else: committed
  end

  defp aliases do
    mutation_paths = [
      "lib/citadel/intent_envelope.ex",
      "lib/citadel/decision_values.ex",
      "lib/citadel/kernel_values.ex",
      "lib/citadel/runtime_values.ex"
    ]

    mutation_aliases =
      Enum.map(mutation_paths, fn path ->
        ~s(muex --files "#{path}" --test-paths "test/citadel" --fail-at 100 --optimize-level conservative)
      end)

    [
      "hardening.adversarial": ["test test/citadel/governance_adversarial_test.exs"],
      "hardening.mutation": mutation_aliases,
      hardening: ["hardening.adversarial", "hardening.mutation"]
    ]
  end

  defp preferred_cli_env do
    [
      muex: :test,
      "hardening.adversarial": :test,
      "hardening.mutation": :test,
      hardening: :test
    ]
  end
end
