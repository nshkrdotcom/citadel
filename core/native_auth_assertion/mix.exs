defmodule Citadel.NativeAuthAssertion.MixProject do
  use Mix.Project

  def project do
    [
      app: :citadel_native_auth_assertion,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "Non-secret native auth assertion refs for governed authority packets"
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
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end
end
