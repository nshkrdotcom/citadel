defmodule Citadel.AuthorityContract.RevisionEpochLeaseContractsTest do
  use ExUnit.Case, async: true

  alias Citadel.AuthorityContract
  alias Citadel.AuthorityContract.InstallationRevisionEpoch.V1, as: InstallationRevisionEpoch
  alias Citadel.AuthorityContract.LeaseRevocation.V1, as: LeaseRevocation

  test "facade exposes revision epoch and lease revocation contract owners" do
    assert AuthorityContract.installation_revision_epoch_module() == InstallationRevisionEpoch
    assert AuthorityContract.lease_revocation_module() == LeaseRevocation

    assert :platform_installation_revision_epoch_v1 in AuthorityContract.manifest().owns
    assert :platform_lease_revocation_v1 in AuthorityContract.manifest().owns
  end

  test "installation revision epoch accepts fenced current epoch evidence" do
    accepted = InstallationRevisionEpoch.new!(base_revision_epoch())

    assert accepted.contract_name == "Platform.InstallationRevisionEpoch.v1"
    assert accepted.fence_status == :accepted
    assert accepted.stale_reason == "none"
    assert InstallationRevisionEpoch.dump(accepted).activation_epoch == 8
  end

  test "installation revision epoch fails closed on missing actor and stale accepted shape" do
    assert {:error, %ArgumentError{message: message}} =
             InstallationRevisionEpoch.new(%{
               base_revision_epoch()
               | principal_ref: nil,
                 system_actor_ref: nil
             })

    assert String.contains?(message, "requires principal_ref or system_actor_ref")

    assert {:error, %ArgumentError{message: message}} =
             InstallationRevisionEpoch.new(%{base_revision_epoch() | stale_reason: "lease_stale"})

    assert String.contains?(message, "accepted fences must use stale_reason none")
  end

  test "installation revision epoch requires stale attempted evidence for rejects" do
    rejected =
      base_revision_epoch()
      |> Map.merge(%{
        fence_status: :rejected,
        stale_reason: "activation_epoch_stale",
        attempted_activation_epoch: 7
      })
      |> InstallationRevisionEpoch.new!()

    assert rejected.fence_status == :rejected
    assert rejected.attempted_activation_epoch == 7

    assert {:error, %ArgumentError{message: message}} =
             InstallationRevisionEpoch.new(%{
               base_revision_epoch()
               | fence_status: :rejected,
                 stale_reason: "none"
             })

    assert String.contains?(message, "rejected fences require stale attempted evidence")
  end

  test "lease revocation accepts durable invalidation evidence" do
    revocation = LeaseRevocation.new!(base_lease_revocation())

    assert revocation.contract_name == "Platform.LeaseRevocation.v1"
    assert revocation.lease_status == :revoked
    assert revocation.lease_scope["allowed_family"] == "runtime_stream"
    assert LeaseRevocation.dump(revocation).revoked_at == ~U[2026-04-18 23:00:00Z]
  end

  test "lease revocation fails closed without revocation evidence" do
    assert {:error, %ArgumentError{message: message}} =
             LeaseRevocation.new(%{base_lease_revocation() | post_revocation_attempt_ref: nil})

    assert String.contains?(message, "post_revocation_attempt_ref")

    assert {:error, %ArgumentError{message: message}} =
             LeaseRevocation.new(%{base_lease_revocation() | lease_scope: %{}})

    assert String.contains?(message, "lease_scope must be a non-empty JSON object")
  end

  defp base_revision_epoch do
    %{
      tenant_ref: "tenant:acme",
      installation_ref: "installation:acme",
      workspace_ref: "workspace:core",
      project_ref: "project:ops",
      environment_ref: "prod",
      principal_ref: "principal:operator-1",
      system_actor_ref: nil,
      resource_ref: "installation:acme",
      authority_packet_ref: "authority-packet:m10",
      permission_decision_ref: "decision:m10",
      idempotency_key: "revision-epoch:m10",
      trace_id: "trace:m10:063",
      correlation_id: "corr:m10:063",
      release_manifest_ref: "phase4-v6-milestone10",
      installation_revision: 12,
      activation_epoch: 8,
      lease_epoch: 4,
      node_id: "node:worker-1",
      fence_decision_ref: "fence:decision:1",
      fence_status: :accepted,
      stale_reason: "none",
      attempted_installation_revision: 12,
      attempted_activation_epoch: 8,
      attempted_lease_epoch: 4
    }
  end

  defp base_lease_revocation do
    %{
      tenant_ref: "tenant:acme",
      installation_ref: "installation:acme",
      workspace_ref: "workspace:core",
      project_ref: "project:ops",
      environment_ref: "prod",
      system_actor_ref: "system:lease-revoker",
      resource_ref: "stream:runtime:1",
      authority_packet_ref: "authority-packet:m10",
      permission_decision_ref: "decision:m10",
      idempotency_key: "lease-revocation:m10",
      trace_id: "trace:m10:077",
      correlation_id: "corr:m10:077",
      release_manifest_ref: "phase4-v6-milestone10",
      lease_ref: "lease:runtime-stream:1",
      revocation_ref: "revocation:lease:1",
      revoked_at: ~U[2026-04-18 23:00:00Z],
      lease_scope: %{"allowed_family" => "runtime_stream", "tenant_ref" => "tenant:acme"},
      cache_invalidation_ref: "cache-invalidation:lease:1",
      post_revocation_attempt_ref: "attempt:lease:after-revoke",
      lease_status: :revoked
    }
  end
end
