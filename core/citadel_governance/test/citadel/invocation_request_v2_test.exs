defmodule Citadel.InvocationRequestV2Test do
  use ExUnit.Case, async: true

  alias Citadel.AuthorityContract.AuthorityDecision.V1, as: AuthorityDecisionV1
  alias Citadel.BoundaryIntent
  alias Citadel.ExecutionGovernance.V1, as: ExecutionGovernanceV1
  alias Citadel.ExecutionGovernanceCompiler
  alias Citadel.InvocationRequest.V2
  alias Citadel.TopologyIntent

  test "freezes the invocation request successor seam with typed execution governance" do
    request = V2.new!(request_attrs())

    assert V2.schema_version() == 2
    assert V2.structured_ingress_posture() == :structured_only
    assert V2.authority_packet_module() == AuthorityDecisionV1
    assert V2.execution_governance_module() == ExecutionGovernanceV1
    assert request.execution_governance.execution_governance_id == "execgov-request-v2-1"
    assert V2.dump(request).execution_governance.sandbox["level"] == "standard"
  end

  test "rejects raw ingress payload keys in provenance for the successor seam" do
    attrs =
      request_attrs()
      |> put_in([:extensions, "citadel", "ingress_provenance", "raw_text"], "open the repo")

    assert_raise ArgumentError, fn ->
      V2.new!(attrs)
    end
  end

  test "rejects missing malformed stale and future schema versions" do
    assert_raise ArgumentError, fn ->
      request_attrs()
      |> Map.delete(:schema_version)
      |> V2.new!()
    end

    for schema_version <- [1, "2", 3] do
      assert_raise ArgumentError, fn ->
        request_attrs()
        |> Map.put(:schema_version, schema_version)
        |> V2.new!()
      end
    end
  end

  defp request_attrs do
    %{
      schema_version: 2,
      invocation_request_id: "invoke-v2-1",
      request_id: "req-v2-1",
      session_id: "sess-v2-1",
      tenant_id: "tenant-v2-1",
      trace_id: "trace-v2-1",
      actor_id: "actor-v2-1",
      target_id: "workspace/main",
      target_kind: "workspace",
      selected_step_id: "step-v2-1",
      allowed_operations: ["write_patch"],
      authority_packet: authority_packet(),
      boundary_intent: boundary_intent(),
      topology_intent: topology_intent(),
      execution_governance: execution_governance(),
      extensions: %{
        "citadel" => %{
          "ingress_provenance" => %{
            "raw_input_refs" => ["raw://intent/1"],
            "raw_input_hashes" => ["sha256:1234abcd"]
          }
        }
      }
    }
  end

  defp authority_packet do
    AuthorityDecisionV1.new!(%{
      contract_version: "v1",
      decision_id: "decision-v2-1",
      tenant_id: "tenant-v2-1",
      request_id: "req-v2-1",
      policy_version: "policy-v2-1",
      boundary_class: "workspace_session",
      trust_profile: "baseline",
      approval_profile: "standard",
      egress_profile: "restricted",
      workspace_profile: "workspace",
      resource_profile: "standard",
      decision_hash: String.duplicate("a", 64),
      extensions: %{"citadel" => %{}}
    })
  end

  defp boundary_intent do
    BoundaryIntent.new!(%{
      boundary_class: "workspace_session",
      trust_profile: "baseline",
      workspace_profile: "workspace",
      resource_profile: "standard",
      requested_attach_mode: "fresh_or_reuse",
      requested_ttl_ms: 300_000,
      extensions: %{}
    })
  end

  defp topology_intent do
    TopologyIntent.new!(%{
      topology_intent_id: "topology-v2-1",
      session_mode: "attached",
      routing_hints: %{"preferred_target_ids" => ["workspace/main"]},
      coordination_mode: "single_target",
      topology_epoch: 1,
      extensions: %{}
    })
  end

  defp execution_governance do
    ExecutionGovernanceCompiler.compile!(
      authority_packet(),
      boundary_intent(),
      topology_intent(),
      execution_governance_id: "execgov-request-v2-1",
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
  end
end
