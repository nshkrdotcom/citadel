defmodule Citadel.Build.WorkspaceContract do
  @moduledoc false

  @package_paths [
    "core/contract_core",
    "core/jido_integration_contracts",
    "core/authority_contract",
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

  @active_project_globs ["."] ++
                          (@package_paths
                           |> Enum.map(&Path.dirname/1)
                           |> Enum.uniq()
                           |> Enum.map(&"#{&1}/*"))

  def package_paths, do: @package_paths
  def active_project_globs, do: @active_project_globs
end
