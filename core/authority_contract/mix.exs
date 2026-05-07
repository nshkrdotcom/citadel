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
      {:execution_plane, path: "../../../execution_plane/core/execution_plane"},
      {:ground_plane_persistence_policy, path: "../../../ground_plane/core/persistence_policy"},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end
end
