if bootstrap = System.get_env("MIX_WORKSPACE_OPS_BOOTSTRAP"), do: Code.require_file(bootstrap)

defmodule Citadel.AuthorityContract.MixProject do
  use Mix.Project

  def project do
    [
      app: :citadel_authority_contract,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "Brain-authored authority packet ownership for Citadel"
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
      workspace_dep({:execution_plane, "~> 0.3.0"}),
      workspace_dep({:ground_plane_persistence_policy, "~> 0.1.0"}),
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp workspace_dep(committed) do
    if function_exported?(MixWorkspaceOpsBootstrap, :dep, 2),
      do: apply(MixWorkspaceOpsBootstrap, :dep, [committed, __DIR__]),
      else: committed
  end
end
