unless Code.ensure_loaded?(Citadel.Build.DependencyResolver) do
  Code.require_file("../../lib/citadel/build/dependency_resolver.ex", __DIR__)
end

defmodule Citadel.TraceBridge.MixProject do
  use Mix.Project

  alias Citadel.Build.DependencyResolver

  def project do
    [
      app: :citadel_trace_bridge,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "Trace publication adapters for Citadel"
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
      {:citadel_observability_contract, path: "../../core/observability_contract"},
      DependencyResolver.ground_plane_contracts(override: true),
      DependencyResolver.aitrace(),
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end
end
