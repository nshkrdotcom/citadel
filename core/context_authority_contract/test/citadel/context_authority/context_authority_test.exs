defmodule Citadel.ContextAuthorityTest do
  use ExUnit.Case, async: true

  alias Citadel.ContextAuthority
  alias Citadel.ContextAuthority.{AuthorityRequest, Grant, RuntimeDeps}
  alias OuterBrain.ContextABI.{ContextPacket, Failure}

  @now ~U[2026-05-24 12:00:00Z]

  test "facade exposes the Context Authority package owners" do
    assert ContextAuthority.authority_request_module() == AuthorityRequest
    assert ContextAuthority.grant_module() == Grant
    assert ContextAuthority.runtime_deps_module() == RuntimeDeps
    assert ContextAuthority.manifest().package == :citadel_context_authority_contract
    assert :context_access_grants in ContextAuthority.manifest().owns
  end

  test "authorizes a matching context packet and emits a ref-only grant" do
    assert {:ok, grant} =
             ContextAuthority.authorize(packet(), request(),
               now: @now,
               allowed_model_classes: ["model-class://frontier", "model-class://local"]
             )

    assert %Grant{} = grant
    assert String.starts_with?(grant.authority_ref, "authority://citadel/context/")
    assert grant.tenant_ref == "tenant://acme"
    assert grant.allowed_model_classes == ["model-class://frontier"]
    assert grant.route_policy_ref == "route-policy://standard"
    assert grant.expires_at == DateTime.add(@now, 300, :second)
    assert grant.payload_mode == :refs_only
    assert grant.metadata["context_packet_ref"] == packet().context_packet_ref
    refute String.contains?(inspect(Grant.dump(grant)), "sk-live")
  end

  test "rejects tenant mismatch and context packet ref mismatch" do
    assert {:error, %Failure{reason_code: "citadel.authority.tenant_mismatch.v1"}} =
             ContextAuthority.authorize(packet(), %{request() | tenant_ref: "tenant://other"})

    assert {:error, %Failure{reason_code: "citadel.authority.packet_ref_mismatch.v1"}} =
             ContextAuthority.authorize(packet(), %{
               request()
               | context_packet_ref: "context-packet://other"
             })
  end

  test "rejects stale policy windows" do
    stale = %{request() | policy_expires_at: ~U[2026-05-24 11:59:59Z]}

    assert {:error, %Failure{reason_code: "citadel.authority.stale_grant.v1"}} =
             ContextAuthority.authorize(packet(), stale, now: @now)
  end

  test "rejects model classes outside the packet or configured policy" do
    outside_packet = %{request() | model_class_allowlist: ["model-class://unknown"]}

    assert {:error, %Failure{reason_code: "citadel.authority.model_class_denied.v1"}} =
             ContextAuthority.authorize(packet(), outside_packet)

    assert {:error, %Failure{reason_code: "citadel.authority.model_class_denied.v1"}} =
             ContextAuthority.authorize(packet(), request(),
               allowed_model_classes: ["model-class://local"]
             )
  end

  test "rejects route policy and raw payload mode downgrade attempts" do
    assert {:error, %Failure{reason_code: "citadel.authority.route_policy_denied.v1"}} =
             ContextAuthority.authorize(packet(), request(),
               allowed_route_policy_refs: ["route-policy://safe-only"]
             )

    assert {:error, %Failure{reason_code: "citadel.authority.payload_mode_denied.v1"}} =
             ContextAuthority.authorize(packet(), %{request() | payload_mode: :raw_payload})
  end

  test "rejects unadmitted trust classes and redaction downgrades" do
    assert {:error, %Failure{reason_code: "citadel.authority.trust_class_denied.v1"}} =
             ContextAuthority.authorize(packet(), %{
               request()
               | trust_classes: [:model_generated_unverified]
             })

    assert {:error, %Failure{reason_code: "citadel.authority.redaction_downgrade_denied.v1"}} =
             ContextAuthority.authorize(
               packet(),
               %{request() | redaction_class: :public_safe},
               minimum_redaction_class: :tenant_sensitive
             )
  end

  test "gates promotion and rollback operations explicitly" do
    assert {:error, %Failure{reason_code: "citadel.authority.operation_denied.v1"}} =
             ContextAuthority.authorize(
               packet(),
               %{request() | operation: :promotion},
               allowed_operations: [:context_access]
             )

    assert {:ok, %Grant{operation: :rollback}} =
             ContextAuthority.authorize(
               packet(),
               %{request() | operation: :rollback},
               allowed_operations: [:rollback]
             )
  end

  test "promotion and rollback operations require explicit evidence refs" do
    assert {:error, %Failure{reason_code: "citadel.authority.missing_evidence.v1"}} =
             ContextAuthority.authorize(packet(), %{request() | operation: :promotion})

    assert {:ok, %Grant{operation: :promotion} = grant} =
             ContextAuthority.authorize(packet(), %{
               request()
               | operation: :promotion,
                 evidence_refs: ["eval://memory/a", "memory-candidate://tenant-a/a"]
             })

    assert "eval://memory/a" in grant.evidence_refs
  end

  defp request do
    AuthorityRequest.new!(%{
      tenant_ref: "tenant://acme",
      actor_ref: "actor://operator/1",
      context_packet_ref: packet().context_packet_ref,
      model_class_allowlist: ["model-class://frontier"],
      route_policy_ref: "route-policy://standard",
      trace_ref: "trace://ctx/1",
      trust_classes: [:operator_authored, :memory_promoted],
      evidence_refs: ["evidence://policy/1"]
    })
  end

  defp packet do
    {:ok, packet} =
      ContextPacket.new(%{
        tenant_ref: "tenant://acme",
        user_request_ref: "artifact://request/1",
        system_instruction_ref: "artifact://system/1",
        memory_refs: ["memory://acme/1"],
        budget_ref: "budget://acme/default",
        model_class_allowlist: ["model-class://frontier", "model-class://local"],
        route_policy_ref: "route-policy://standard",
        trace_ref: "trace://ctx/1"
      })

    packet
  end
end
