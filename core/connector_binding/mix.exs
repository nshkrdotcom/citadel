defmodule Citadel.ConnectorBinding.MixProject do
  use Mix.Project

  def project do
    [
      app: :citadel_connector_binding,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "Ref-only connector binding identity and lifecycle contracts",
      docs: [main: "readme", extras: ["README.md"]]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:citadel_authority_contract, path: "../authority_contract"},
      {:citadel_contract_core, path: "../contract_core"},
      {:citadel_kernel, path: "../citadel_kernel"},
      {:citadel_governance, path: "../citadel_governance"},
      {:citadel_provider_auth_fabric, path: "../provider_auth_fabric"},
      {:citadel_observability_contract, path: "../observability_contract"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false}
    ]
  end
end
