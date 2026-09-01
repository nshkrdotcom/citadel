if bootstrap = System.get_env("MIX_WORKSPACE_OPS_BOOTSTRAP"), do: Code.require_file(bootstrap)

defmodule Citadel.ProviderAuthFabric.MixProject do
  use Mix.Project

  def project do
    [
      app: :citadel_provider_auth_fabric,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description:
        "Provider auth registration, leasing, materialization, revocation, audit, and redaction contracts"
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:citadel_kernel, path: "../citadel_kernel"},
      {:citadel_authority_contract, path: "../authority_contract"},
      {:citadel_contract_core, path: "../contract_core"},
      {:citadel_policy_packs, path: "../policy_packs"},
      {:citadel_observability_contract, path: "../observability_contract"},
      {:citadel_native_auth_assertion, path: "../native_auth_assertion"},
      workspace_dep({:jido_integration_provider_classification, "~> 0.1.0"}),
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp workspace_dep(committed) do
    if function_exported?(MixWorkspaceOpsBootstrap, :dep, 2),
      do: apply(MixWorkspaceOpsBootstrap, :dep, [committed, __DIR__]),
      else: committed
  end
end
