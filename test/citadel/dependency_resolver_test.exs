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

  test "resolver source selection does not read process env" do
    source = File.read!(@resolver_source)

    refute String.contains?(source, "System.get_env")
    refute String.contains?(source, "System.fetch_env")
    refute String.contains?(source, "System.put_env")
    refute String.contains?(source, "System.delete_env")
  end

  test "defaults the shared contracts dependency to the sibling jido_integration checkout" do
    assert DependencyResolver.jido_integration_contracts_source() ==
             {:path, Path.expand("../jido_integration/core/contracts", File.cwd!())}
  end

  test "defaults provider classification to the dependency-light sibling package" do
    assert {:jido_integration_provider_classification, opts} =
             DependencyResolver.jido_integration_provider_classification()

    assert opts[:path] ==
             Path.expand("../jido_integration/core/provider_classification", File.cwd!())
  end

  test "defaults the aitrace dependency to the sibling AITrace checkout" do
    assert DependencyResolver.aitrace_source() ==
             {:path, Path.expand("../AITrace", File.cwd!())}
  end

  test "published requirements remain explicit without env toggles" do
    assert DependencyResolver.published_jido_integration_contracts_requirement() == "~> 0.1.0"
    assert DependencyResolver.published_aitrace_requirement() == "~> 0.2.0"
    assert DependencyResolver.published_execution_plane_requirement() == "~> 0.3.0"
    assert DependencyResolver.published_ground_plane_contracts_requirement() == "~> 0.1.0"

    assert DependencyResolver.published_ground_plane_persistence_policy_requirement() ==
             "~> 0.1.0"
  end
end
