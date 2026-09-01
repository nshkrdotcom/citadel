if bootstrap = System.get_env("MIX_WORKSPACE_OPS_BOOTSTRAP"), do: Code.require_file(bootstrap)

defmodule Citadel.Conformance.MixProject do
  use Mix.Project

  def project do
    [
      app: :citadel_conformance,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "Black-box conformance and composition coverage for Citadel"
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:citadel_contract_core, path: "../contract_core"},
      {:citadel_authority_contract, path: "../authority_contract"},
      {:citadel_execution_governance_contract, path: "../execution_governance_contract"},
      {:citadel_observability_contract, path: "../observability_contract"},
      {:citadel_policy_packs, path: "../policy_packs"},
      {:citadel_governance, path: "../citadel_governance"},
      {:citadel_kernel, path: "../citadel_kernel"},
      {:citadel_invocation_bridge, path: "../../bridges/invocation_bridge"},
      {:citadel_query_bridge, path: "../../bridges/query_bridge"},
      {:citadel_signal_bridge, path: "../../bridges/signal_bridge"},
      {:citadel_boundary_bridge, path: "../../bridges/boundary_bridge"},
      {:citadel_projection_bridge, path: "../../bridges/projection_bridge"},
      {:citadel_trace_bridge, path: "../../bridges/trace_bridge"},
      {:citadel_coding_assist, path: "../../apps/coding_assist"},
      {:citadel_operator_assist, path: "../../apps/operator_assist"},
      {:citadel_host_surface_harness, path: "../../apps/host_surface_harness"},
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
