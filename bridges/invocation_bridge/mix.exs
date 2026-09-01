if bootstrap = System.get_env("MIX_WORKSPACE_OPS_BOOTSTRAP"), do: Code.require_file(bootstrap)

defmodule Citadel.InvocationBridge.MixProject do
  use Mix.Project

  def project do
    [
      app: :citadel_invocation_bridge,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "Invocation handoff adapters for Citadel"
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:citadel_governance, path: "../../core/citadel_governance"},
      {:citadel_kernel, path: "../../core/citadel_kernel"},
      {:citadel_authority_contract, path: "../../core/authority_contract"},
      {:citadel_execution_governance_contract, path: "../../core/execution_governance_contract"},
      {:citadel_observability_contract, path: "../../core/observability_contract"},
      workspace_dep({:jido_integration_contracts, "~> 0.1.0"}),
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp workspace_dep(committed) do
    if function_exported?(MixWorkspaceOpsBootstrap, :dep, 2),
      do: apply(MixWorkspaceOpsBootstrap, :dep, [committed, __DIR__]),
      else: committed
  end
end
