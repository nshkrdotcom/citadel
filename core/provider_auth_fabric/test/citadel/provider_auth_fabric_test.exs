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

  test "redacts known protected values" do
    receipt =
      ProviderAuthFabric.redact(
        %{error: "provider returned sk-live-token"},
        ["sk-live-token"]
      )

    refute inspect(receipt) =~ "sk-live-token"
    assert inspect(receipt) =~ "[REDACTED]"
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
      target_ref: "target://sandbox/a",
      attach_grant_ref: "attach-grant://tenant/sandbox/a",
      authority_packet_ref: "authority-packet://tenant/run/a",
      expires_at: ~U[2026-05-04 00:00:00Z]
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
