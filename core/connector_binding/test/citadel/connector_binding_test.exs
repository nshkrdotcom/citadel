defmodule Citadel.ConnectorBindingTest do
  use ExUnit.Case, async: true

  alias Citadel.ConnectorBinding

  test "binds connector instance independently from provider account and credential refs" do
    assert {:ok, binding} = ConnectorBinding.bind(valid_attrs())

    assert binding.connector_binding_ref == "connector-binding://tenant-1/codex/default"
    assert binding.connector_instance_ref == "connector-instance://tenant-1/codex/default"
    assert binding.provider_account_ref == "provider-account://tenant-1/codex/account-a"
    assert binding.credential_handle_ref == "credential-handle://tenant-1/codex/account-a/primary"
    refute binding.connector_instance_ref == binding.provider_account_ref
    refute binding.connector_instance_ref == binding.credential_handle_ref

    assert ConnectorBinding.redacted_evidence(binding).raw_material_present? == false
  end

  test "two accounts under one provider cannot merge identity scope" do
    assert {:ok, left} = ConnectorBinding.bind(valid_attrs())

    assert {:ok, right} =
             valid_attrs()
             |> Map.put(:provider_account_ref, "provider-account://tenant-1/codex/account-b")
             |> Map.put(
               :credential_handle_ref,
               "credential-handle://tenant-1/codex/account-b/primary"
             )
             |> Map.put(:connector_binding_ref, "connector-binding://tenant-1/codex/account-b")
             |> ConnectorBinding.bind()

    refute ConnectorBinding.same_identity_scope?(left, right)
    refute ConnectorBinding.identity_key(left) == ConnectorBinding.identity_key(right)
  end

  test "provider name or connector instance alone cannot select a credential" do
    assert {:error, {:missing_required_refs, missing_from_provider_only}} =
             %{provider_family: "codex", provider_ref: "provider://codex"}
             |> ConnectorBinding.bind()

    assert :provider_account_ref in missing_from_provider_only
    assert :credential_handle_ref in missing_from_provider_only
    assert :connector_instance_ref in missing_from_provider_only

    assert {:error, {:missing_required_refs, missing_from_connector_only}} =
             %{
               provider_family: "codex",
               provider_ref: "provider://codex",
               connector_instance_ref: "connector-instance://tenant-1/codex/default"
             }
             |> ConnectorBinding.bind()

    assert :provider_account_ref in missing_from_connector_only
    assert :credential_handle_ref in missing_from_connector_only
  end

  test "identity lookup is tenant scoped and policy revision scoped" do
    assert {:ok, original} = ConnectorBinding.bind(valid_attrs())

    assert {:ok, different_tenant} =
             valid_attrs()
             |> Map.put(:tenant_ref, "tenant://tenant-2")
             |> Map.put(:policy_revision_ref, "policy-revision://tenant-2/auth/1")
             |> Map.put(:provider_account_ref, "provider-account://tenant-2/codex/account-a")
             |> Map.put(:connector_instance_ref, "connector-instance://tenant-2/codex/default")
             |> Map.put(:connector_binding_ref, "connector-binding://tenant-2/codex/default")
             |> Map.put(
               :credential_handle_ref,
               "credential-handle://tenant-2/codex/account-a/primary"
             )
             |> Map.put(:target_ref, "target://tenant-2/sandbox/a")
             |> Map.put(:attach_grant_ref, "attach-grant://tenant-2/sandbox/a")
             |> Map.put(:operation_policy_ref, "operation-policy://tenant-2/codex/chat")
             |> Map.put(:evidence_ref, "evidence://tenant-2/connector-binding/1")
             |> Map.put(:redaction_ref, "redaction://tenant-2/connector-binding/1")
             |> ConnectorBinding.bind()

    assert {:ok, different_policy} =
             valid_attrs()
             |> Map.put(:policy_revision_ref, "policy-revision://tenant-1/auth/2")
             |> Map.put(:connector_binding_ref, "connector-binding://tenant-1/codex/policy-2")
             |> ConnectorBinding.bind()

    refute ConnectorBinding.same_identity_scope?(original, different_tenant)
    refute ConnectorBinding.same_identity_scope?(original, different_policy)
  end

  test "rejects raw credential material and ref conflation" do
    assert {:error, {:raw_material_rejected, forbidden}} =
             valid_attrs()
             |> Map.put(:raw_token, "secret")
             |> Map.put(:metadata, %{provider_payload: %{}})
             |> ConnectorBinding.bind()

    assert Enum.sort(forbidden) == [:provider_payload, :raw_token]

    same_ref = "provider-account://tenant-1/codex/account-a"

    assert {:error, {:ref_conflation_rejected, conflicts}} =
             valid_attrs()
             |> Map.put(:connector_instance_ref, same_ref)
             |> ConnectorBinding.bind()

    assert {:connector_instance_ref, :provider_account_ref} in conflicts
  end

  test "bounds lifecycle and provider account status values" do
    assert {:ok, binding} =
             valid_attrs()
             |> Map.put(:provider_account_status, "asserted")
             |> Map.put(:lifecycle, "active")
             |> ConnectorBinding.bind()

    assert binding.provider_account_status == :asserted
    assert binding.lifecycle == :active

    assert {:error, {:invalid_enum_value, :provider_account_status, :stale, _allowed}} =
             valid_attrs()
             |> Map.put(:provider_account_status, :stale)
             |> ConnectorBinding.bind()

    assert {:error, {:invalid_enum_value, :lifecycle, :paused, _allowed}} =
             valid_attrs()
             |> Map.put(:lifecycle, :paused)
             |> ConnectorBinding.bind()
  end

  test "authorizes credential leases only when binding scope aligns" do
    assert {:ok, binding} = ConnectorBinding.bind(valid_attrs())

    assert :ok = ConnectorBinding.authorize_lease(binding, lease_scope())

    assert {:error, {:lease_scope_mismatch, [:provider_account_ref]}} =
             ConnectorBinding.authorize_lease(
               binding,
               Map.put(
                 lease_scope(),
                 :provider_account_ref,
                 "provider-account://tenant-1/codex/account-b"
               )
             )

    assert {:error, {:lease_scope_mismatch, [:credential_handle_ref]}} =
             ConnectorBinding.authorize_lease(
               binding,
               Map.put(
                 lease_scope(),
                 :credential_handle_ref,
                 "credential-handle://tenant-1/codex/account-b/primary"
               )
             )

    assert {:error, {:lease_scope_mismatch, [:policy_revision_ref]}} =
             ConnectorBinding.authorize_lease(
               binding,
               Map.put(lease_scope(), :policy_revision_ref, "policy-revision://tenant-1/auth/2")
             )
  end

  defp valid_attrs do
    %{
      tenant_ref: "tenant://tenant-1",
      policy_revision_ref: "policy-revision://tenant-1/auth/1",
      provider_ref: "provider://codex",
      provider_family: "codex",
      provider_account_ref: "provider-account://tenant-1/codex/account-a",
      provider_account_status: :known,
      connector_instance_ref: "connector-instance://tenant-1/codex/default",
      connector_binding_ref: "connector-binding://tenant-1/codex/default",
      credential_handle_ref: "credential-handle://tenant-1/codex/account-a/primary",
      credential_lease_ref: "credential-lease://tenant-1/codex/account-a/lease-1",
      target_ref: "target://tenant-1/sandbox/a",
      attach_grant_ref: "attach-grant://tenant-1/sandbox/a",
      operation_policy_ref: "operation-policy://tenant-1/codex/chat",
      evidence_ref: "evidence://tenant-1/connector-binding/1",
      redaction_ref: "redaction://tenant-1/connector-binding/1",
      lifecycle: :validated,
      metadata: %{identity_introspection: :ref_only}
    }
  end

  defp lease_scope do
    %{
      tenant_ref: "tenant://tenant-1",
      policy_revision_ref: "policy-revision://tenant-1/auth/1",
      provider_account_ref: "provider-account://tenant-1/codex/account-a",
      connector_instance_ref: "connector-instance://tenant-1/codex/default",
      connector_binding_ref: "connector-binding://tenant-1/codex/default",
      credential_handle_ref: "credential-handle://tenant-1/codex/account-a/primary",
      credential_lease_ref: "credential-lease://tenant-1/codex/account-a/lease-1",
      target_ref: "target://tenant-1/sandbox/a",
      attach_grant_ref: "attach-grant://tenant-1/sandbox/a",
      operation_policy_ref: "operation-policy://tenant-1/codex/chat"
    }
  end
end
