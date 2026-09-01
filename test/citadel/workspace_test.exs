defmodule Citadel.WorkspaceTest do
  use ExUnit.Case, async: true

  alias Citadel.Workspace
  alias Citadel.Workspace.MixProject
  alias Weld

  test "tracks the packet workspace package contract on disk" do
    assert Workspace.package_count() == 24
    assert Workspace.package_count() == length(Workspace.package_paths())
    assert "apps/host_surface_harness" in Workspace.package_paths()
    assert "core/execution_governance_contract" in Workspace.package_paths()
    assert "core/context_authority_contract" in Workspace.package_paths()
    refute "core/jido_integration_contracts" in Workspace.package_paths()
    assert "core/native_auth_assertion" in Workspace.package_paths()
    assert "core/provider_auth_fabric" in Workspace.package_paths()
    assert "core/connector_binding" in Workspace.package_paths()
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

  test "limits packet seam atom lint to runtime source paths" do
    refute "build_support" in Workspace.static_analysis_paths()
    assert "lib" in Workspace.static_analysis_paths()
    assert "core/*/lib" in Workspace.static_analysis_paths()
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

  test "ci regenerates the retained distribution projection and checks drift" do
    aliases = MixProject.project()[:aliases]

    assert aliases[:ci] |> List.last() == "dist.generated.verify"

    assert aliases[:"dist.generated.verify"] == [
             "weld.verify",
             "cmd git diff --exit-code -- dist/hex/citadel"
           ]
  end

  test "classifies retained distribution trees as generated output" do
    assert Workspace.generated_distribution_roots() == [
             "dist/hex",
             "dist/release_bundles",
             "dist/archive"
           ]

    assert Workspace.generated_distribution_path?("dist/hex/citadel/mix.exs")
    assert Workspace.generated_distribution_path?("dist/release_bundles/citadel/README.md")
    assert Workspace.generated_distribution_path?("dist/archive/old-citadel/components/core")
    assert Workspace.generated_distribution_path?("/tmp/work/citadel/dist/hex/citadel/mix.exs")

    refute Workspace.generated_distribution_path?("core/citadel_kernel/mix.exs")
    refute Workspace.generated_distribution_path?("docs/publication.md")
    refute Enum.any?(Workspace.package_paths(), &Workspace.generated_distribution_path?/1)
    refute Enum.any?(Workspace.static_analysis_paths(), &Workspace.generated_distribution_path?/1)
  end

  test "defines a derivative welded publication boundary" do
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
             "core/connector_binding",
             "core/context_authority_contract",
             "core/provider_auth_fabric"
           ]

    assert Enum.sort(Workspace.public_bridge_package_paths()) ==
             Enum.sort(
               Enum.filter(Workspace.package_paths(), &String.starts_with?(&1, "bridges/"))
             )

    refute "core/conformance" in Workspace.public_package_paths()
    refute "apps/host_surface_harness" in Workspace.public_package_paths()
    assert "surfaces/citadel_domain_surface" in Workspace.public_package_paths()
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
    assert "core/connector_binding" in result.artifact.selected_projects
    assert "core/context_authority_contract" in result.artifact.selected_projects
    assert "core/provider_auth_fabric" in result.artifact.selected_projects
    assert "core/native_auth_assertion" in result.artifact.selected_projects
    refute "core/jido_integration_contracts" in result.artifact.selected_projects
    assert "bridges/host_ingress_bridge" in result.artifact.selected_projects
    assert "bridges/jido_integration_bridge" in result.artifact.selected_projects
    assert "bridges/trace_bridge" in result.artifact.selected_projects
    assert "bridges/projection_bridge" in result.artifact.selected_projects
    refute "core/conformance" in result.artifact.selected_projects
    refute "apps/host_surface_harness" in result.artifact.selected_projects
    refute "surfaces/citadel_domain_surface" in result.artifact.selected_projects

    assert "aitrace" in result.artifact.external_deps
    assert "execution_plane" in result.artifact.external_deps
    assert "ground_plane_contracts" in result.artifact.external_deps
    assert "jido_integration_contracts" in result.artifact.external_deps
    assert "jido_integration_provider_classification" in result.artifact.external_deps
    assert "outer_brain_context_abi" in result.artifact.external_deps
  end

  test "weld manifest can be inspected through the mix task entrypoint" do
    {output, 0} =
      System.cmd("mix", ["weld.inspect"], stderr_to_stdout: true)

    assert String.contains?(output, "citadel")
  end
end
