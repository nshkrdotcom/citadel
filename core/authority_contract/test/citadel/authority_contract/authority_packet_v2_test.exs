defmodule Citadel.AuthorityContract.AuthorityPacket.V2Test do
  use ExUnit.Case, async: true

  alias Citadel.AuthorityContract
  alias Citadel.AuthorityContract.AuthorityPacket.V2

  test "exposes the Phase 4 authority packet surface through the facade" do
    assert AuthorityContract.manifest().status == :phase_4_authority_packet_hardened
    assert AuthorityContract.authority_packet_module() == V2
    assert AuthorityContract.packet_name() == "Citadel.AuthorityPacketV2.v1"
    assert AuthorityContract.contract_version() == "1.0.0"
    assert AuthorityContract.extensions_namespaces() == ["citadel"]
    assert :principal_ref_or_system_actor_ref in AuthorityContract.required_fields()
    assert :canonical_json_hash in AuthorityContract.required_fields()
  end

  test "computes stable authority hashes over the canonical packet payload" do
    packet = sample_attrs() |> V2.put_hashes!()

    assert V2.hashes_valid?(packet)
    assert packet.decision_hash == packet.canonical_json_hash
    assert lower_hex_64?(packet.decision_hash)

    tampered =
      packet
      |> V2.dump()
      |> Map.put(:action, "execution.run.escalated")
      |> V2.new!()

    refute V2.hashes_valid?(tampered)
  end

  test "requires an actor and rejects extension namespaces outside citadel" do
    assert_raise ArgumentError, fn ->
      sample_attrs()
      |> Map.delete(:principal_ref)
      |> V2.put_hashes!()
    end

    assert_raise ArgumentError, fn ->
      sample_attrs()
      |> Map.put(:extensions, %{"other" => %{}})
      |> V2.put_hashes!()
    end
  end

  test "carries Phase 2 ref families without materialized provider secrets" do
    packet =
      sample_attrs()
      |> Map.merge(%{
        system_authorization_ref: "system-authority://tenant/operator/a",
        provider_family: "codex",
        provider_ref: "provider://codex",
        provider_account_ref: "provider-account://tenant/codex/a",
        connector_instance_ref: "connector-instance://tenant/codex/a",
        connector_binding_ref: "connector-binding://tenant/codex/a",
        credential_handle_ref: "credential-handle://tenant/codex/a",
        credential_lease_ref: "credential-lease://tenant/codex/a/1",
        native_auth_assertion_ref: "native-auth-assertion://codex/root-a",
        operation_policy_ref: "operation-policy://tenant/codex/run",
        operation_scope_ref: "operation-scope://tenant/codex/run",
        target_ref: "target://sandbox/a",
        attach_grant_ref: "attach-grant://tenant/sandbox/a",
        authority_decision_ref: "authority-decision://tenant/run/a",
        redaction_ref: "redaction://tenant/policy/a"
      })
      |> V2.put_hashes!()

    dumped = V2.dump(packet)

    assert dumped.system_authorization_ref == "system-authority://tenant/operator/a"
    assert dumped.provider_account_ref == "provider-account://tenant/codex/a"
    assert dumped.credential_handle_ref == "credential-handle://tenant/codex/a"
    assert dumped.attach_grant_ref == "attach-grant://tenant/sandbox/a"
    refute inspect(dumped) =~ "sk-live"
  end

  test "rejects oversized authority packet hash input before canonical JSON encoding" do
    attrs =
      sample_attrs()
      |> Map.put(:extensions, %{
        "citadel" => %{"oversized_context" => String.duplicate("x", 1_100_000)}
      })

    assert_raise ArgumentError, fn ->
      V2.put_hashes!(attrs)
    end
  end

  defp lower_hex_64?(value) do
    byte_size(value) == 64 and
      value
      |> :binary.bin_to_list()
      |> Enum.all?(fn byte -> byte in ?0..?9 or byte in ?a..?f end)
  end

  defp sample_attrs do
    %{
      contract_name: "Citadel.AuthorityPacketV2.v1",
      contract_version: "1.0.0",
      authority_packet_ref: "authpkt-1",
      permission_decision_ref: "decision-1",
      tenant_ref: "tenant-1",
      installation_ref: "installation-1",
      workspace_ref: "workspace-1",
      project_ref: "project-1",
      environment_ref: "dev",
      principal_ref: "principal-1",
      resource_ref: "resource-1",
      subject_ref: "subject-1",
      action: "execution.run",
      policy_revision: "policy-rev-1",
      installation_revision: 12,
      activation_epoch: 4,
      boundary_class: "operator_command",
      trust_profile: "strict",
      approval_profile: "operator-approved",
      egress_profile: "none",
      workspace_profile: "tenant-workspace",
      resource_profile: "execution-resource",
      idempotency_key: "idempotency-1",
      trace_id: "trace-1",
      correlation_id: "correlation-1",
      release_manifest_ref: "phase4-v6-milestone4-authority-packet-rejection-hardening",
      extensions: %{"citadel" => %{"policy_pack_ref" => "pack-1"}}
    }
  end
end
