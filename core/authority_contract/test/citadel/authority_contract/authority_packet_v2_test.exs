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
