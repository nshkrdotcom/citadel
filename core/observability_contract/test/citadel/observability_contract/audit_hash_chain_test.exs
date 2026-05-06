defmodule Citadel.ObservabilityContract.AuditHashChainTest do
  use ExUnit.Case, async: true

  alias Citadel.ObservabilityContract
  alias Citadel.ObservabilityContract.AuditHashChain.V1, as: AuditHashChain

  test "facade exposes audit hash chain contract owner" do
    assert ObservabilityContract.audit_hash_chain_module() == AuditHashChain
    assert :platform_audit_hash_chain_v1 in ObservabilityContract.manifest().owns
  end

  test "accepts immutable audit link evidence" do
    link = AuditHashChain.new!(base_link())

    assert link.contract_name == "Platform.AuditHashChain.v1"
    assert link.previous_hash == AuditHashChain.genesis_hash()
    assert AuditHashChain.dump(link).chain_head_hash == valid_hash("head")
  end

  test "fails closed without actor or hash evidence" do
    assert {:error, %ArgumentError{message: message}} =
             AuditHashChain.new(%{base_link() | principal_ref: nil, system_actor_ref: nil})

    assert String.contains?(message, "requires principal_ref or system_actor_ref")

    assert {:error, %ArgumentError{message: message}} =
             AuditHashChain.new(%{base_link() | event_hash: "not-a-hash"})

    assert String.contains?(message, "event_hash must be a sha256 hash")
  end

  test "verifies chain continuity without rewriting previous links" do
    first = AuditHashChain.new!(base_link())

    second =
      base_link()
      |> Map.merge(%{
        audit_ref: "audit:m13:071:2",
        previous_hash: first.chain_head_hash,
        event_hash: valid_hash("event-2"),
        chain_head_hash: valid_hash("head-2"),
        immutability_proof_ref: "immutability-proof:m13:071:2"
      })
      |> AuditHashChain.new!()

    assert :ok = AuditHashChain.verify_link(first, second)

    tampered =
      second
      |> AuditHashChain.dump()
      |> Map.put(:previous_hash, valid_hash("tampered"))
      |> AuditHashChain.new!()

    assert {:error, :chain_continuity_violation} =
             AuditHashChain.verify_link(first, tampered)
  end

  defp base_link do
    %{
      tenant_ref: "tenant:acme",
      installation_ref: "installation:acme",
      workspace_ref: "workspace:core",
      project_ref: "project:ops",
      environment_ref: "prod",
      principal_ref: "principal:operator-1",
      system_actor_ref: nil,
      resource_ref: "audit://phase4/m13/071",
      authority_packet_ref: "authority-packet:m13:071",
      permission_decision_ref: "permission-decision:m13:071",
      idempotency_key: "audit-hash-chain:m13:071",
      trace_id: "trace:m13:071",
      correlation_id: "correlation:m13:071",
      release_manifest_ref: "phase4-v6-milestone13",
      audit_ref: "audit:m13:071:1",
      previous_hash: AuditHashChain.genesis_hash(),
      event_hash: valid_hash("event-1"),
      chain_head_hash: valid_hash("head"),
      writer_ref: "writer:citadel:audit",
      immutability_proof_ref: "immutability-proof:m13:071:1"
    }
  end

  defp valid_hash(seed) do
    "sha256:" <> Base.encode16(:crypto.hash(:sha256, seed), case: :lower)
  end
end
