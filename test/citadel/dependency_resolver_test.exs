defmodule Citadel.DependencyResolverTest do
  use ExUnit.Case, async: false

  alias Citadel.Build.DependencyResolver

  @resolver_source Path.expand("../../lib/citadel/build/dependency_resolver.ex", __DIR__)
  @conformance_source Path.expand("../../core/conformance/lib/citadel/conformance.ex", __DIR__)

  test "resolver and conformance sources avoid hard-coded checkout paths" do
    assert File.read!(@resolver_source) != ""
    assert File.read!(@conformance_source) != ""

    refute String.contains?(File.read!(@resolver_source), "/home/home/p/g/n/")
    refute String.contains?(File.read!(@conformance_source), "/home/home/p/g/n/")
  end

  test "defaults the shared contracts dependency to the sibling jido_integration checkout" do
    with_env(
      [
        {"CITADEL_JIDO_INTEGRATION_CONTRACTS_PATH", nil},
        {"JIDO_INTEGRATION_PATH", nil}
      ],
      fn ->
        assert DependencyResolver.jido_integration_contracts_source() ==
                 {:path, Path.expand("../jido_integration/core/contracts", File.cwd!())}
      end
    )
  end

  test "defaults the aitrace dependency to the sibling AITrace checkout" do
    with_env(
      [
        {"AITRACE_PATH", nil}
      ],
      fn ->
        assert DependencyResolver.aitrace_source() ==
                 {:path, Path.expand("../AITrace", File.cwd!())}
      end
    )
  end

  test "published mode disables local sibling fallbacks" do
    with_env(
      [
        {"CITADEL_JIDO_INTEGRATION_CONTRACTS_PATH", "published"},
        {"JIDO_INTEGRATION_PATH", nil},
        {"AITRACE_PATH", "published"}
      ],
      fn ->
        assert DependencyResolver.jido_integration_contracts_source() == {:hex, "~> 0.1.0"}
        assert DependencyResolver.aitrace_source() == {:hex, "~> 0.1.0"}
      end
    )
  end

  defp with_env(overrides, fun) do
    previous =
      Enum.map(overrides, fn {name, _value} ->
        {name, System.get_env(name)}
      end)

    try do
      Enum.each(overrides, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)

      fun.()
    after
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end
  end
end
