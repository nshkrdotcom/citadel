defmodule Citadel.ExecutionGovernanceCompilerTest do
  use ExUnit.Case, async: true

  alias Citadel.AuthorityContract.AuthorityDecision.V1, as: AuthorityDecisionV1
  alias Citadel.BoundaryIntent
  alias Citadel.ExecutionGovernance.V1, as: ExecutionGovernanceV1
  alias Citadel.ExecutionGovernanceCompiler
  alias Citadel.TopologyIntent

  test "compiles authority, boundary, topology, and realized execution attrs into execution governance" do
    packet =
      ExecutionGovernanceCompiler.compile!(
        authority_packet(),
        boundary_intent(),
        topology_intent(),
        execution_governance_id: "execgov-compiler-1",
        sandbox_level: "standard",
        sandbox_egress: "restricted",
        sandbox_approvals: "auto",
        acceptable_attestation: ["local-erlexec-weak", "spiffe://prod/microvm-strict@v1"],
        allowed_tools: ["write_patch", "read_repo"],
        file_scope_ref: "workspace://project/main",
        file_scope_hint: "apps/citadel",
        logical_workspace_ref: "workspace://project/main",
        workspace_mutability: "read_write",
        execution_family: "process",
        placement_intent: "host_local",
        target_kind: "workspace",
        allowed_operations: ["write_patch"],
        effect_classes: ["filesystem_write"],
        extensions: %{"citadel" => %{"selection_source" => "compiler_test"}}
      )

    assert %ExecutionGovernanceV1{} = packet
    assert packet.authority_ref["decision_id"] == "decision-compiler-1"
    assert packet.sandbox["level"] == "standard"

    assert packet.sandbox["acceptable_attestation"] == [
             "local-erlexec-weak",
             "spiffe://prod/microvm-strict@v1"
           ]

    assert packet.sandbox["allowed_tools"] == ["write_patch", "read_repo"]
    assert packet.workspace["logical_workspace_ref"] == "workspace://project/main"
    assert packet.resources["resource_profile"] == "standard"
    assert packet.placement["execution_family"] == "process"
    assert packet.operations["effect_classes"] == ["filesystem_write"]
    assert packet.extensions["citadel"]["selection_source"] == "compiler_test"

    assert packet.extensions["citadel"]["persistence_posture"]["persistence_profile_ref"] ==
             "persistence-profile://mickey_mouse"

    assert packet.extensions["citadel"]["persistence_posture"]["durable?"] == false
  end

  test "does not require node-local absolute paths" do
    packet =
      ExecutionGovernanceCompiler.compile!(
        authority_packet(),
        boundary_intent(),
        topology_intent(),
        execution_governance_id: "execgov-compiler-2",
        sandbox_level: "strict",
        sandbox_egress: "blocked",
        sandbox_approvals: "manual",
        acceptable_attestation: ["spiffe://prod/microvm-strict@v1"],
        allowed_tools: ["read_repo"],
        file_scope_ref: "workspace://tenant-x/project-y",
        logical_workspace_ref: "workspace://tenant-x/project-y",
        workspace_mutability: "read_only",
        execution_family: "process",
        placement_intent: "remote_workspace",
        target_kind: "workspace",
        node_affinity: "cell-a",
        allowed_operations: ["inspect_repo"],
        effect_classes: []
      )

    assert packet.sandbox["file_scope_ref"] == "workspace://tenant-x/project-y"
    assert packet.sandbox["file_scope_hint"] == nil
    assert packet.placement["node_affinity"] == "cell-a"
  end

  test "carries Phase 7 action-bound authority into execution governance extensions" do
    packet =
      ExecutionGovernanceCompiler.compile!(
        authority_packet(for_action_ref: "action://agent-loop/turn-1"),
        boundary_intent(),
        topology_intent(),
        execution_governance_id: "execgov-compiler-action",
        sandbox_level: "standard",
        sandbox_egress: "restricted",
        sandbox_approvals: "auto",
        acceptable_attestation: ["local-erlexec-weak"],
        allowed_tools: ["write_patch"],
        file_scope_ref: "workspace://project/main",
        logical_workspace_ref: "workspace://project/main",
        workspace_mutability: "read_write",
        execution_family: "process",
        placement_intent: "host_local",
        target_kind: "workspace",
        allowed_operations: ["write_patch"],
        effect_classes: []
      )

    assert packet.extensions["citadel"]["for_action_ref"] == "action://agent-loop/turn-1"
  end

  defp authority_packet(opts \\ []) do
    AuthorityDecisionV1.new!(%{
      contract_version: "v1",
      decision_id: "decision-compiler-1",
      tenant_id: "tenant-1",
      request_id: "req-1",
      policy_version: "policy-2026-04-11",
      boundary_class: "workspace_session",
      trust_profile: "trusted_operator",
      approval_profile: "approval_optional",
      egress_profile: "restricted",
      workspace_profile: "project_workspace",
      resource_profile: "standard",
      decision_hash: String.duplicate("a", 64),
      extensions: %{
        "citadel" =>
          if(for_action_ref = Keyword.get(opts, :for_action_ref),
            do: %{"for_action_ref" => for_action_ref},
            else: %{}
          )
      }
    })
  end

  defp boundary_intent do
    BoundaryIntent.new!(%{
      boundary_class: "workspace_session",
      trust_profile: "trusted_operator",
      workspace_profile: "project_workspace",
      resource_profile: "standard",
      requested_attach_mode: "fresh_or_reuse",
      requested_ttl_ms: 30_000,
      extensions: %{}
    })
  end

  defp topology_intent do
    TopologyIntent.new!(%{
      topology_intent_id: "topology-compiler-1",
      session_mode: "attached",
      routing_hints: %{"execution_intent_family" => "process"},
      coordination_mode: "single_target",
      topology_epoch: 1,
      extensions: %{}
    })
  end
end
