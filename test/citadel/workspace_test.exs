defmodule Citadel.WorkspaceTest do
  use ExUnit.Case, async: true

  alias Citadel.Workspace
  alias Citadel.Workspace.MixProject
  alias Weld

  test "tracks the packet workspace package contract on disk" do
    assert Workspace.package_count() == 23
    assert Workspace.package_count() == length(Workspace.package_paths())
    assert "apps/host_surface_harness" in Workspace.package_paths()
    assert "core/execution_governance_contract" in Workspace.package_paths()
    assert "core/jido_integration_contracts" in Workspace.package_paths()
    assert "core/native_auth_assertion" in Workspace.package_paths()
    assert "core/provider_auth_fabric" in Workspace.package_paths()
    assert "bridges/host_ingress_bridge" in Workspace.package_paths()
    assert "bridges/jido_integration_bridge" in Workspace.package_paths()
    assert "surfaces/citadel_domain_surface" in Workspace.package_paths()
    assert Workspace.missing_package_paths() == []

    assert Enum.all?(Workspace.package_paths(), fn path ->
             File.regular?(Path.join(path, "mix.exs")) and
               File.regular?(Path.join(path, "README.md"))
           end)
  end

  test "pins the packet toolchain baseline" do
    assert Workspace.toolchain() == %{elixir: "~> 1.19", otp: "28"}
  end

  test "uses the released Weld 0.7.2 line directly" do
    assert {:weld, "~> 0.7.2", runtime: false} in MixProject.project()[:deps]
  end

  test "uses Weld task autodiscovery instead of local release aliases" do
    aliases = MixProject.project()[:aliases]

    for alias_name <- [
          :"weld.inspect",
          :"weld.verify",
          :"weld.release.prepare",
          :"weld.release.track",
          :"weld.release.archive",
          :"release.prepare",
          :"release.track",
          :"release.archive"
        ] do
      refute Keyword.has_key?(aliases, alias_name)
    end
  end

  test "exposes an explicit shared-contract dependency strategy" do
    assert match?({:path, _path}, Workspace.shared_contract_dependency_source()) or
             match?({:hex, "~> 0.1.0"}, Workspace.shared_contract_dependency_source())
  end

  test "defines a derivative welded publication boundary" do
    publication_deps = Workspace.publication_dependency_declarations()

    assert Workspace.proof_package_paths() == [
             "core/conformance",
             "apps/coding_assist",
             "apps/operator_assist",
             "apps/host_surface_harness"
           ]

    assert Workspace.tooling_project_paths() == ["."]
    assert Workspace.surface_package_paths() == ["surfaces/citadel_domain_surface"]
    assert Workspace.publication_artifact_id() == "citadel"
    assert Workspace.publication_manifest_path() == "packaging/weld/citadel.exs"

    assert Workspace.publication_root_projects() == [
             "core/citadel_kernel",
             "core/provider_auth_fabric"
           ]

    assert Enum.sort(Workspace.public_bridge_package_paths()) ==
             Enum.sort(
               Enum.filter(Workspace.package_paths(), &String.starts_with?(&1, "bridges/"))
             )

    refute "core/conformance" in Workspace.public_package_paths()
    refute "apps/host_surface_harness" in Workspace.public_package_paths()
    assert "surfaces/citadel_domain_surface" in Workspace.public_package_paths()

    refute Keyword.has_key?(publication_deps, :jido_integration_contracts)
    assert publication_deps[:aitrace][:opts] == []
    assert is_binary(publication_deps[:aitrace][:requirement])

    assert execution_plane_dependency_declared?(publication_deps[:execution_plane])
  end

  test "weld manifest keeps publication derivative of the workspace architecture" do
    result = Weld.inspect!(Workspace.publication_manifest_path())

    assert result.manifest.artifact == "citadel"
    assert result.artifact.roots == Workspace.publication_root_projects()
    assert result.violations == []

    assert "." in result.classifications.tooling
    assert "core/conformance" in result.classifications.proof
    assert "apps/host_surface_harness" in result.classifications.proof

    assert "core/citadel_kernel" in result.artifact.selected_projects
    assert "core/provider_auth_fabric" in result.artifact.selected_projects
    assert "core/native_auth_assertion" in result.artifact.selected_projects
    assert "core/jido_integration_contracts" in result.artifact.selected_projects
    assert "bridges/host_ingress_bridge" in result.artifact.selected_projects
    assert "bridges/jido_integration_bridge" in result.artifact.selected_projects
    assert "bridges/trace_bridge" in result.artifact.selected_projects
    assert "bridges/projection_bridge" in result.artifact.selected_projects
    refute "core/conformance" in result.artifact.selected_projects
    refute "apps/host_surface_harness" in result.artifact.selected_projects
    refute "surfaces/citadel_domain_surface" in result.artifact.selected_projects

    assert "aitrace" in result.artifact.external_deps
    assert "execution_plane" in result.artifact.external_deps
    refute "jido_integration_contracts" in result.artifact.external_deps
  end

  test "weld manifest can be inspected through the mix task entrypoint" do
    {output, 0} =
      System.cmd("mix", ["weld.inspect"],
        env: [
          {"CITADEL_JIDO_INTEGRATION_CONTRACTS_PATH", "published"},
          {"AITRACE_PATH", "published"}
        ],
        stderr_to_stdout: true
      )

    assert output =~ "citadel"
  end

  defp execution_plane_dependency_declared?(%{requirement: requirement, opts: []})
       when is_binary(requirement),
       do: true

  defp execution_plane_dependency_declared?(%{requirement: nil, opts: opts}) do
    to_string(opts[:git]) =~ "/execution_plane" and opts[:subdir] == "core/execution_plane"
  end

  defp execution_plane_dependency_declared?(dependency) when is_list(dependency) do
    execution_plane_dependency_declared?(Map.new(dependency))
  end

  defp execution_plane_dependency_declared?(_other), do: false
end
