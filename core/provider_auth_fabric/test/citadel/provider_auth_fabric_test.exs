defmodule Citadel.ProviderAuthFabricTest do
  use ExUnit.Case, async: true

  alias Citadel.ProviderAuthFabric

  test "rejects missing universal authority before provider effects" do
    assert {:error, {:missing_authority_refs, missing}} =
             %{}
             |> Map.merge(effect_refs())
             |> Map.delete(:authority_packet_ref)
             |> ProviderAuthFabric.authorize_provider_effect()

    assert :authority_packet_ref in missing
  end

  test "rejects system, provider, credential, target, and attach ref substitution" do
    attrs =
      effect_refs()
      |> Map.put(:system_authorization_ref, "credential-handle://tenant/codex/a")
      |> Map.put(:credential_handle_ref, "system-authority://tenant/system")
      |> Map.put(:target_ref, "provider-account://tenant/codex/a")
      |> Map.put(:attach_grant_ref, "target://sandbox/a")

    assert {:error, {:ref_family_mismatch, fields}} =
             ProviderAuthFabric.authorize_provider_effect(attrs)

    assert Enum.sort(fields) ==
             [:attach_grant_ref, :credential_handle_ref, :system_authorization_ref, :target_ref]
  end

  test "rejects provider singleton and raw credential material" do
    attrs =
      effect_refs()
      |> Map.put(:singleton_client, :provider_default)
      |> Map.put(:raw_token, "sk-live-token")

    assert {:error, {:raw_material_rejected, fields}} =
             ProviderAuthFabric.authorize_provider_effect(attrs)

    assert Enum.sort(fields) == [:raw_token, :singleton_client]
  end

  test "registers account, issues handle and lease, then emits revoke and audit refs" do
    assert {:ok, registration} = ProviderAuthFabric.register_provider_account(registration_refs())
    assert {:ok, handle} = ProviderAuthFabric.issue_credential_handle(registration, handle_refs())
    assert {:ok, lease} = ProviderAuthFabric.issue_lease(handle, lease_refs())

    assert lease.credential_handle_ref == handle.credential_handle_ref
    assert lease.attach_grant_ref == "attach-grant://tenant/sandbox/a"

    assert {:ok, revoked} =
             ProviderAuthFabric.revoke(handle, %{
               authority_packet_ref: "authority-packet://tenant/run/a",
               system_authorization_ref: "system-authority://tenant/operator/a"
             })

    assert revoked.status == :revoked

    assert {:ok, audit} =
             ProviderAuthFabric.audit_event("provider_auth.materialized", %{
               authority_packet_ref: "authority-packet://tenant/run/a",
               system_authorization_ref: "system-authority://tenant/operator/a",
               redaction_ref: "redaction://tenant/policy/a",
               metadata: %{credential_handle_ref: handle.credential_handle_ref}
             })

    assert audit.metadata.credential_handle_ref == handle.credential_handle_ref
  end

  test "redeems governed leases only for matching provider account, operation, policy, target, and fence scope" do
    assert {:ok, registration} = ProviderAuthFabric.register_provider_account(registration_refs())
    assert {:ok, handle} = ProviderAuthFabric.issue_credential_handle(registration, handle_refs())
    assert {:ok, lease} = ProviderAuthFabric.issue_lease(handle, lease_refs())

    assert {:ok, evidence} =
             ProviderAuthFabric.redeem_lease(lease, redemption_refs())

    assert evidence.credential_lease_ref == lease.credential_lease_ref
    assert evidence.redacted == true

    assert {:error, :provider_account_mismatch} =
             ProviderAuthFabric.redeem_lease(
               lease,
               Map.put(
                 redemption_refs(),
                 :provider_account_ref,
                 "provider-account://tenant/codex/b"
               )
             )

    assert {:error, :operation_class_mismatch} =
             ProviderAuthFabric.redeem_lease(
               lease,
               Map.put(redemption_refs(), :operation_class, "http")
             )

    assert {:error, :stale_policy_revision} =
             ProviderAuthFabric.redeem_lease(
               lease,
               Map.put(
                 redemption_refs(),
                 :policy_revision_ref,
                 "policy-revision://tenant/codex/2"
               )
             )

    assert {:error, :stale_rotation_epoch} =
             ProviderAuthFabric.redeem_lease(
               lease,
               Map.put(redemption_refs(), :rotation_epoch, 2)
             )

    assert {:error, :stale_target_grant} =
             ProviderAuthFabric.redeem_lease(
               lease,
               Map.put(
                 redemption_refs(),
                 :target_grant_revision,
                 "target-grant-revision://tenant/sandbox/2"
               )
             )
  end

  test "renews, revokes, cleans, audits, and fences leases without raw material" do
    assert {:ok, registration} = ProviderAuthFabric.register_provider_account(registration_refs())
    assert {:ok, handle} = ProviderAuthFabric.issue_credential_handle(registration, handle_refs())
    assert {:ok, lease} = ProviderAuthFabric.issue_lease(handle, lease_refs())

    assert {:ok, renewed} =
             ProviderAuthFabric.renew_lease(
               lease,
               Map.merge(lease_refs(), %{
                 credential_lease_ref: "credential-lease://tenant/codex/a/2",
                 fence_token: "fence://tenant/codex/a/2"
               })
             )

    assert renewed.renewed_from_lease_ref == lease.credential_lease_ref

    assert {:ok, revoked} =
             ProviderAuthFabric.revoke_lease(lease, %{
               authority_packet_ref: "authority-packet://tenant/run/a",
               system_authorization_ref: "system-authority://tenant/operator/a",
               revocation_ref: "revocation://tenant/codex/a/1",
               revoked_at: ~U[2026-05-04 00:01:00Z]
             })

    assert revoked.status == :revoked

    assert {:ok, cleanup} =
             ProviderAuthFabric.cleanup_lease(lease, %{
               cleanup_ref: "cleanup://tenant/codex/a/1",
               cleaned_at: ~U[2026-05-04 00:02:00Z]
             })

    assert cleanup.status == :cleaned

    assert {:ok, audit} =
             ProviderAuthFabric.audit_lease_event("provider_auth.lease.redeemed", lease, %{
               redaction_ref: "redaction://tenant/policy/a",
               metadata: %{raw_token: "sk-live-token"}
             })

    assert audit.redacted == true
    refute String.contains?(inspect(audit), "sk-live-token")

    assert {:ok, fence} =
             ProviderAuthFabric.fence_event(lease, %{checked_at: ~U[2026-05-04 00:03:00Z]})

    assert fence.fence_token == "fence://tenant/codex/a/1"
    refute Map.has_key?(fence, :payload)
  end

  test "redacts known protected values" do
    receipt =
      ProviderAuthFabric.redact(
        %{error: "provider returned sk-live-token"},
        ["sk-live-token"]
      )

    refute String.contains?(inspect(receipt), "sk-live-token")
    assert String.contains?(inspect(receipt), "[REDACTED]")
  end

  defp registration_refs do
    %{
      registration_ref: "provider-registration://tenant/codex/a",
      system_actor_ref: "system-actor://tenant/operator/a",
      system_authorization_ref: "system-authority://tenant/operator/a",
      provider_family: "codex",
      provider_account_ref: "provider-account://tenant/codex/a",
      connector_instance_ref: "connector-instance://tenant/codex/a",
      operation_policy_ref: "operation-policy://tenant/codex/run",
      target_ref: "target://sandbox/a",
      redaction_ref: "redaction://tenant/policy/a"
    }
  end

  defp handle_refs do
    %{
      credential_handle_ref: "credential-handle://tenant/codex/a"
    }
  end

  defp lease_refs do
    %{
      credential_lease_ref: "credential-lease://tenant/codex/a/1",
      tenant_ref: "tenant://tenant",
      subject_ref: "subject://tenant/codex/user-a",
      provider_family: "codex",
      connector_instance_ref: "connector-instance://tenant/codex/a",
      operation_class: "cli",
      target_ref: "target://sandbox/a",
      attach_grant_ref: "attach-grant://tenant/sandbox/a",
      authority_packet_ref: "authority-packet://tenant/run/a",
      policy_revision_ref: "policy-revision://tenant/codex/1",
      target_grant_revision: "target-grant-revision://tenant/sandbox/1",
      rotation_epoch: 1,
      fence_token: "fence://tenant/codex/a/1",
      expires_at: ~U[2026-05-04 00:00:00Z]
    }
  end

  defp redemption_refs do
    %{
      tenant_ref: "tenant://tenant",
      subject_ref: "subject://tenant/codex/user-a",
      provider_family: "codex",
      provider_account_ref: "provider-account://tenant/codex/a",
      connector_instance_ref: "connector-instance://tenant/codex/a",
      credential_handle_ref: "credential-handle://tenant/codex/a",
      operation_class: "cli",
      target_ref: "target://sandbox/a",
      attach_grant_ref: "attach-grant://tenant/sandbox/a",
      operation_policy_ref: "operation-policy://tenant/codex/run",
      policy_revision_ref: "policy-revision://tenant/codex/1",
      target_grant_revision: "target-grant-revision://tenant/sandbox/1",
      rotation_epoch: 1,
      fence_token: "fence://tenant/codex/a/1",
      now: ~U[2026-05-03 23:59:00Z]
    }
  end

  defp effect_refs do
    %{
      authority_packet_ref: "authority-packet://tenant/run/a",
      system_actor_ref: "system-actor://tenant/operator/a",
      system_authorization_ref: "system-authority://tenant/operator/a",
      provider_family: "codex",
      provider_account_ref: "provider-account://tenant/codex/a",
      connector_instance_ref: "connector-instance://tenant/codex/a",
      credential_handle_ref: "credential-handle://tenant/codex/a",
      credential_lease_ref: "credential-lease://tenant/codex/a/1",
      operation_policy_ref: "operation-policy://tenant/codex/run",
      target_ref: "target://sandbox/a",
      attach_grant_ref: "attach-grant://tenant/sandbox/a",
      policy_revision_ref: "policy-revision://tenant/codex/1",
      redaction_ref: "redaction://tenant/policy/a"
    }
  end
end
