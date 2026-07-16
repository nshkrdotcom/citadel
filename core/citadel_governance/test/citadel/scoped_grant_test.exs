defmodule Citadel.ScopedGrantTest do
  use ExUnit.Case, async: true

  alias Citadel.{GrantEnforcementReceipt, GrantVerificationError, ScopedGrant}

  @hash String.duplicate("c", 64)
  @issued_at ~U[2026-07-15 12:00:00Z]
  @expires_at ~U[2026-07-15 12:05:00Z]
  @scope %{
    "provider_ref" => "provider://google/gemini",
    "account_ref" => "account://google/acme-primary",
    "target_ref" => "target://nshkr/local",
    "generation" => 7,
    "fence" => 19
  }

  defp attrs do
    %{
      contract_version: 1,
      grant_ref: "grant://citadel/model/run-1",
      decision_ref: "decision://citadel/model/run-1",
      decision_hash: @hash,
      policy_artifact_ref: "artifact://citadel/policy/model-v1",
      policy_version: 1,
      input_snapshot_hash: "sha256:" <> @hash,
      tenant_ref: "tenant://acme",
      actor_ref: "actor://synapse/operator",
      subject_ref: "subject://synapse/run-1",
      effect_ref: "effect://mezzanine/model/run-1",
      operation_ref: "operation://jido/gemini/generate-content",
      capability_id: "model.gemini.managed-account.local-effect",
      scope: @scope,
      obligations: [%{"type" => "record_usage", "required" => true}],
      result: "permitted",
      issued_at: @issued_at,
      expires_at: @expires_at,
      status: "active"
    }
  end

  defp expected do
    Map.take(attrs(), [
      :tenant_ref,
      :actor_ref,
      :subject_ref,
      :effect_ref,
      :operation_ref,
      :capability_id,
      :scope
    ])
  end

  test "verifies only the exact active unexpired scope" do
    grant = ScopedGrant.new!(attrs())
    assert :ok = ScopedGrant.verify(grant, expected(), ~U[2026-07-15 12:01:00Z])
    assert String.starts_with?(ScopedGrant.digest(grant), "sha256:")

    mismatched = put_in(expected(), [:scope, "account_ref"], "account://google/other")

    assert {:error,
            %GrantVerificationError{category: :scope_mismatch, reason: :exact_scope_mismatch}} =
             ScopedGrant.verify(grant, mismatched, ~U[2026-07-15 12:01:00Z])

    assert {:error, %GrantVerificationError{category: :scope_mismatch}} =
             ScopedGrant.verify(
               grant,
               Map.put(expected(), :ignored_constraint, "must-not-be-ignored"),
               ~U[2026-07-15 12:01:00Z]
             )
  end

  test "verification rejects reconstructed invalid grants and malformed requests" do
    grant = ScopedGrant.new!(attrs())

    assert {:error, %GrantVerificationError{category: :invalid, reason: :invalid_grant}} =
             grant
             |> Map.put(:status, "unexpected")
             |> ScopedGrant.verify(expected(), ~U[2026-07-15 12:01:00Z])

    assert {:error, %GrantVerificationError{category: :invalid, reason: :invalid_grant}} =
             grant
             |> Map.put(:expires_at, "not-a-datetime")
             |> ScopedGrant.verify(expected(), ~U[2026-07-15 12:01:00Z])

    assert {:error, %GrantVerificationError{category: :invalid, reason: :invalid_expected_scope}} =
             ScopedGrant.verify(grant, [:not_a_key_value], ~U[2026-07-15 12:01:00Z])

    assert {:error, %GrantVerificationError{category: :invalid, reason: :invalid_expected_scope}} =
             ScopedGrant.verify(
               grant,
               %{{:invalid, :key} => "value"},
               ~U[2026-07-15 12:01:00Z]
             )
  end

  test "rejects expiry and revocation without downgrade" do
    grant = ScopedGrant.new!(attrs())

    assert {:error, %GrantVerificationError{category: :expired}} =
             ScopedGrant.verify(grant, expected(), @expires_at)

    assert {:ok, revoked} =
             ScopedGrant.revoke(
               grant,
               "revocation://citadel/model/run-1",
               ~U[2026-07-15 12:02:00Z]
             )

    assert {:error, %GrantVerificationError{category: :revoked}} =
             ScopedGrant.verify(revoked, expected(), ~U[2026-07-15 12:03:00Z])

    assert {:error, :invalid_grant_transition} =
             ScopedGrant.revoke(
               revoked,
               "revocation://citadel/model/run-1/again",
               ~U[2026-07-15 12:03:00Z]
             )

    assert {:error, :invalid_grant_revocation} =
             ScopedGrant.revoke(
               grant,
               "revocation://citadel/model/run-1/too-early",
               ~U[2026-07-15 11:59:59Z]
             )

    assert {:error, :invalid_grant_transition} =
             ScopedGrant.revoke(grant, "revocation://citadel/model/run-1", "not-a-datetime")
  end

  test "rejects secret-bearing scope and obligations" do
    assert {:error, {:secret_key_forbidden, "api_key"}} =
             attrs() |> put_in([:scope, "api_key"], "sentinel-secret") |> ScopedGrant.new()

    assert {:error, {:secret_key_forbidden, "raw_credential"}} =
             attrs()
             |> Map.put(:obligations, [%{"raw_credential" => "sentinel-secret"}])
             |> ScopedGrant.new()

    assert {:error, {:secret_key_forbidden, "credential_material"}} =
             attrs()
             |> put_in([:scope, "credential-material"], "sentinel-secret")
             |> ScopedGrant.new()

    assert {:error, {:secret_key_forbidden, "provider_token"}} =
             attrs() |> put_in([:scope, "provider-token"], "sentinel-secret") |> ScopedGrant.new()

    assert {:error, :invalid_grant_key} =
             attrs() |> put_in([:scope, {:invalid, :key}], "value") |> ScopedGrant.new()

    assert {:error, :invalid_scoped_grant} = ScopedGrant.new([:not_a_key_value])

    assert {:error, :invalid_grant_digest_input} =
             attrs()
             |> put_in([:scope, "bounded_value"], String.duplicate("x", 70_000))
             |> ScopedGrant.new()
  end

  test "constructs a bounded enforcement receipt" do
    assert {:ok, receipt} =
             GrantEnforcementReceipt.new(
               receipt_ref: "receipt://citadel/enforcement/run-1",
               grant_ref: "grant://citadel/model/run-1",
               decision_ref: "decision://citadel/model/run-1",
               effect_ref: "effect://mezzanine/model/run-1",
               operation_ref: "operation://jido/gemini/generate-content",
               attempt_ref: "attempt://jido/run-1/1",
               boundary_ref: "boundary://jido/materializer/gemini",
               result: :enforced,
               enforced_at: ~U[2026-07-15 12:01:00Z]
             )

    assert receipt.result == "enforced"
    assert {:ok, ^receipt} = GrantEnforcementReceipt.new(receipt)

    assert {:error, :invalid_grant_enforcement_receipt} =
             receipt
             |> Map.from_struct()
             |> Map.put(:token, "sentinel-secret")
             |> GrantEnforcementReceipt.new()

    assert {:error, :invalid_grant_enforcement_receipt} =
             GrantEnforcementReceipt.new([:not_a_key_value])
  end
end
