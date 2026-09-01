defmodule Citadel.Workspace do
  @moduledoc """
  Packet-aligned metadata for the Citadel non-umbrella workspace.

  This root module exists so the workspace tooling project has a concrete,
  testable surface without pretending to be the old single-package runtime.
  """

  @package_paths [
    "core/contract_core",
    "core/authority_contract",
    "core/context_authority_contract",
    "core/observability_contract",
    "core/policy_packs",
    "core/citadel_governance",
    "core/citadel_kernel",
    "core/execution_governance_contract",
    "core/native_auth_assertion",
    "core/provider_auth_fabric",
    "core/connector_binding",
    "core/conformance",
    "bridges/invocation_bridge",
    "bridges/host_ingress_bridge",
    "bridges/jido_integration_bridge",
    "bridges/query_bridge",
    "bridges/signal_bridge",
    "bridges/boundary_bridge",
    "bridges/projection_bridge",
    "bridges/trace_bridge",
    "apps/coding_assist",
    "apps/operator_assist",
    "apps/host_surface_harness",
    "surfaces/citadel_domain_surface"
  ]
  @active_project_globs [".", "core/*", "bridges/*", "apps/*", "surfaces/*"]
  @surface_package_paths ["surfaces/citadel_domain_surface"]
  @proof_package_paths [
    "core/conformance",
    "apps/coding_assist",
    "apps/operator_assist",
    "apps/host_surface_harness"
  ]
  @static_analysis_paths [
    "lib",
    "core/*/lib",
    "bridges/*/lib",
    "apps/host_surface_harness/lib",
    "surfaces/*/lib"
  ]
  @packet_seam_spec_paths [
    "core/citadel_governance/lib/citadel/invocation_request.ex",
    "core/citadel_governance/lib/citadel/ports.ex",
    "core/citadel_kernel/lib/citadel/kernel/trace_publisher.ex",
    "bridges/invocation_bridge/lib/citadel/invocation_bridge.ex",
    "bridges/query_bridge/lib/citadel/query_bridge.ex",
    "bridges/signal_bridge/lib/citadel/signal_bridge.ex",
    "bridges/boundary_bridge/lib/citadel/boundary_bridge.ex",
    "bridges/boundary_bridge/lib/citadel/boundary_bridge/boundary_projection_adapter.ex",
    "bridges/projection_bridge/lib/citadel/projection_bridge.ex",
    "bridges/projection_bridge/lib/citadel/projection_bridge/review_projection_adapter.ex",
    "bridges/projection_bridge/lib/citadel/projection_bridge/derived_state_attachment_adapter.ex"
  ]
  @tooling_project_paths ["."]
  @public_bridge_package_paths [
    "bridges/invocation_bridge",
    "bridges/host_ingress_bridge",
    "bridges/jido_integration_bridge",
    "bridges/query_bridge",
    "bridges/signal_bridge",
    "bridges/boundary_bridge",
    "bridges/projection_bridge",
    "bridges/trace_bridge"
  ]
  @public_package_paths @package_paths -- @proof_package_paths
  @publication_artifact_id "citadel"
  @publication_manifest_path "packaging/weld/citadel.exs"
  @publication_root_projects [
    "core/citadel_kernel",
    "core/connector_binding",
    "core/context_authority_contract",
    "core/provider_auth_fabric"
  ]
  @publication_output_docs [
    "README.md",
    "docs/README.md",
    "core/context_authority_contract/README.md",
    "docs/shared_contract_dependency_strategy.md",
    "docs/workspace_topology.md",
    "docs/publication.md",
    "CHANGELOG.md",
    "LICENSE"
  ]
  @publication_output_assets ["assets/citadel.svg"]
  @generated_distribution_roots [
    "dist/hex",
    "dist/release_bundles",
    "dist/archive"
  ]
  @generated_distribution_segment_pairs Enum.map(
                                          @generated_distribution_roots,
                                          &String.split(&1, "/")
                                        )

  @toolchain %{
    elixir: "~> 1.19",
    otp: "28"
  }

  @publication_dependency_declarations [
    aitrace: [requirement: "~> 0.2.0", opts: []],
    execution_plane: [requirement: "~> 0.3.0", opts: []],
    ground_plane_contracts: [requirement: "~> 0.1.0", opts: [override: true]],
    ground_plane_persistence_policy: [requirement: "~> 0.1.0", opts: [override: true]],
    outer_brain_context_abi: [requirement: "~> 0.1.0", opts: [override: true]],
    jido_integration_contracts: [requirement: "~> 0.1.0", opts: [override: true]],
    jido_integration_provider_classification: [
      requirement: "~> 0.1.0",
      opts: [override: true]
    ]
  ]

  @spec package_paths() :: [String.t()]
  def package_paths, do: @package_paths

  @spec package_count() :: pos_integer()
  def package_count, do: length(@package_paths)

  @spec proof_package_paths() :: [String.t()]
  def proof_package_paths, do: @proof_package_paths

  @spec surface_package_paths() :: [String.t()]
  def surface_package_paths, do: @surface_package_paths

  @spec static_analysis_paths() :: [String.t()]
  def static_analysis_paths, do: @static_analysis_paths

  @spec generated_distribution_roots() :: [String.t()]
  def generated_distribution_roots, do: @generated_distribution_roots

  @spec generated_distribution_path?(Path.t()) :: boolean()
  def generated_distribution_path?(path) when is_binary(path) do
    segments = Path.split(path)

    Enum.any?(@generated_distribution_segment_pairs, fn segment_pair ->
      contains_segment_sequence?(segments, segment_pair)
    end)
  end

  @spec packet_seam_spec_paths() :: [String.t()]
  def packet_seam_spec_paths, do: @packet_seam_spec_paths

  @spec tooling_project_paths() :: [String.t()]
  def tooling_project_paths, do: @tooling_project_paths

  @spec public_bridge_package_paths() :: [String.t()]
  def public_bridge_package_paths, do: @public_bridge_package_paths

  @spec public_package_paths() :: [String.t()]
  def public_package_paths, do: @public_package_paths

  @spec missing_package_paths() :: [String.t()]
  def missing_package_paths do
    @package_paths
    |> Enum.reject(&File.regular?(Path.join(&1, "mix.exs")))
  end

  @spec toolchain() :: %{elixir: String.t(), otp: String.t()}
  def toolchain, do: @toolchain

  @spec publication_artifact_id() :: String.t()
  def publication_artifact_id, do: @publication_artifact_id

  @spec publication_manifest_path() :: String.t()
  def publication_manifest_path, do: @publication_manifest_path

  @spec publication_root_projects() :: [String.t()]
  def publication_root_projects, do: @publication_root_projects

  @spec publication_output_docs() :: [String.t()]
  def publication_output_docs, do: @publication_output_docs

  @spec publication_output_assets() :: [String.t()]
  def publication_output_assets, do: @publication_output_assets

  @spec publication_internal_only_projects() :: [String.t()]
  def publication_internal_only_projects do
    @tooling_project_paths ++ @proof_package_paths
  end

  @spec publication_dependency_declarations() :: keyword()
  def publication_dependency_declarations, do: @publication_dependency_declarations

  @spec weld_manifest() :: keyword()
  def weld_manifest do
    [
      workspace: [
        root: "../..",
        project_globs: @active_project_globs
      ],
      classify: [
        tooling: @tooling_project_paths,
        proofs: @proof_package_paths
      ],
      publication: [
        internal_only: publication_internal_only_projects()
      ],
      dependencies: publication_dependency_declarations(),
      artifacts: [
        citadel: [
          roots: @publication_root_projects,
          include: @public_bridge_package_paths,
          package: [
            name: @publication_artifact_id,
            otp_app: :citadel,
            version: "0.1.0",
            elixir: @toolchain.elixir,
            description:
              "Runtime-facing Citadel core packages and bridge adapters projected from the workspace",
            licenses: ["MIT"],
            maintainers: ["nshkrdotcom"],
            development_dependencies: [
              {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
              {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
            ],
            links: %{
              "GitHub" => "https://github.com/nshkrdotcom/citadel",
              "Publication Guide" =>
                "https://github.com/nshkrdotcom/citadel/blob/main/docs/publication.md",
              "Changelog" => "https://github.com/nshkrdotcom/citadel/blob/main/CHANGELOG.md"
            },
            docs_main: "workspace_topology"
          ],
          output: [
            docs: @publication_output_docs,
            assets: @publication_output_assets
          ],
          verify: [
            artifact_tests: ["packaging/weld/citadel/test"],
            hex_build: false,
            hex_publish: false
          ]
        ]
      ]
    ]
  end

  defp contains_segment_sequence?(segments, sequence) do
    sequence_length = length(sequence)

    segments
    |> Enum.chunk_every(sequence_length, 1, :discard)
    |> Enum.any?(&(&1 == sequence))
  end
end
