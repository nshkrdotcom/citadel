defmodule Citadel.Governance.ModelAuthorityTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Citadel.Governance.DurableSchemas.AuthorityDecision
  alias Citadel.Governance.DurableSchemas.ScopedGrantRecord
  alias Citadel.Governance.ModelAuthority
  alias Citadel.Governance.Repo
  alias Citadel.GrantVerificationError
  alias Citadel.ModelGrant
  alias Citadel.PolicyPacks.ModelInvocationPolicy
  alias Citadel.ScopedGrant

  @issued_at ~U[2026-07-20 12:00:00.000000Z]
  @expires_at ~U[2026-07-20 12:01:00.000000Z]
  @context_digest "sha256:" <> String.duplicate("c", 64)

  setup_all do
    start_supervised!(Repo)
    migrations = Application.app_dir(:citadel_governance, "priv/repo/migrations")
    Ecto.Migrator.run(Repo, migrations, :up, all: true)
    :ok
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  test "evaluates and persists the exact Gemini decision and model grant" do
    attrs = issue_attrs()
    policy = ModelInvocationPolicy.synapse_gemini_turn!()
    assert {:ok, input_digest} = ModelAuthority.input_digest(attrs)

    assert {:ok, %{result: :permitted, decision: decision, grant: grant}} =
             ModelAuthority.evaluate_and_persist(attrs, policy)

    assert %ModelGrant{
             input_digest: ^input_digest,
             policy_ref: "policy-artifact://citadel/synapse/gemini-turn/v1",
             provider_family: "google_gemini",
             account_ref: "provider-account://tenant-acme/google-gemini/primary",
             model_ref: "gemini-2.5-flash",
             operation_class: "generate_content",
             context_digest: @context_digest,
             status: "active"
           } = grant

    assert decision.input_snapshot_hash == input_digest
    assert decision.decision_payload["input_digest"] == input_digest
    assert decision.decision_payload["input_snapshot"]["attempt_ref"] == attrs.attempt_ref
    assert decision.decision_payload["input_snapshot"]["fence_ref"] == attrs.fence_token
    refute Map.has_key?(decision.decision_payload["input_snapshot"], "fence_token")
    assert decision.decision_payload["policy_artifact"]["source_digest"] == policy.source_digest

    assert Repo.aggregate(
             from(d in AuthorityDecision, where: d.decision_ref == ^attrs.decision_ref),
             :count
           ) == 1

    assert Repo.aggregate(
             from(g in ScopedGrantRecord, where: g.grant_ref == ^attrs.grant_ref),
             :count
           ) == 1

    assert {:ok, ^grant} = ModelAuthority.fetch_grant(attrs.grant_ref)
    assert :ok = ModelAuthority.verify_grant(attrs.grant_ref, grant_binding(grant), @issued_at)

    assert {:ok, %{result: :permitted, decision: ^decision, grant: ^grant}} =
             ModelAuthority.evaluate_and_persist(attrs, policy)
  end

  test "verification rejects reuse across every authority dimension" do
    attrs = issue_attrs()

    assert {:ok, %{grant: grant}} =
             ModelAuthority.evaluate_and_persist(
               attrs,
               ModelInvocationPolicy.synapse_gemini_turn!()
             )

    mismatches = [
      decision_ref: unique_ref("decision-other"),
      input_digest: "sha256:" <> String.duplicate("d", 64),
      policy_ref: "policy-artifact://citadel/other/v1",
      policy_version: 2,
      tenant_ref: "tenant://other",
      actor_ref: "actor://other",
      subject_ref: "subject://other",
      provider_family: "openai",
      account_ref: "provider-account://other",
      model_ref: "gemini-2.5-pro",
      operation_ref: "operation://gemini/other",
      operation_class: "stream_generate_content",
      context_ref: "context://outer-brain/other",
      context_digest: "sha256:" <> String.duplicate("e", 64),
      attempt_ref: "attempt://jido/other",
      effect_ref: "effect://mezzanine/other",
      fence_token: "fence://account/other"
    ]

    Enum.each(mismatches, fn {field, value} ->
      assert {:error,
              %GrantVerificationError{
                category: :scope_mismatch,
                reason: :model_grant_binding_mismatch
              }} =
               ModelAuthority.verify_grant(
                 grant.grant_ref,
                 Map.put(grant_binding(grant), field, value),
                 @issued_at
               )
    end)
  end

  test "expiry, revocation, and closed authority state fail closed" do
    attrs = issue_attrs()

    assert {:ok, %{grant: grant}} =
             ModelAuthority.evaluate_and_persist(
               attrs,
               ModelInvocationPolicy.synapse_gemini_turn!()
             )

    assert {:error, %GrantVerificationError{category: :expired}} =
             ModelAuthority.verify_grant(grant.grant_ref, grant_binding(grant), @expires_at)

    revoked_at = DateTime.add(@issued_at, 30, :second)

    assert {:ok, %ModelGrant{status: "revoked"}} =
             ModelAuthority.revoke_grant(grant.grant_ref, %{
               revocation_ref: unique_ref("revocation"),
               revoked_at: revoked_at,
               reason_ref: "reason://citadel/model-account-revoked"
             })

    assert {:error, %GrantVerificationError{category: :revoked}} =
             ModelAuthority.verify_grant(grant.grant_ref, grant_binding(grant), revoked_at)
  end

  test "policy denials are durable and never mint a grant" do
    policy = ModelInvocationPolicy.synapse_gemini_turn!()

    for {field, value, reason} <- [
          {:provider_family, "openai", :provider_not_allowed},
          {:model_ref, "gemini-2.5-pro", :model_not_allowed},
          {:operation_class, "list_models", :operation_not_allowed},
          {:expires_at, DateTime.add(@issued_at, 121, :second), :grant_ttl_not_allowed}
        ] do
      attrs = issue_attrs() |> unique_issue_refs() |> Map.put(field, value)

      assert {:ok, %{result: :denied, reason: ^reason, decision: decision}} =
               ModelAuthority.evaluate_and_persist(attrs, policy)

      assert decision.result == "denied"
      assert decision.decision_payload["reason"] == Atom.to_string(reason)
      assert Repo.get(ScopedGrantRecord, attrs.grant_ref) == nil
    end
  end

  test "invalid and broadened reconstructed model grants are rejected" do
    attrs = issue_attrs()

    assert {:ok, %{grant: model_grant}} =
             ModelAuthority.evaluate_and_persist(
               attrs,
               ModelInvocationPolicy.synapse_gemini_turn!()
             )

    assert {:ok, %ScopedGrant{} = scoped_grant} =
             Citadel.Governance.DurableAuthority.fetch_grant(model_grant.grant_ref)

    assert {:error, :invalid_model_grant} =
             ModelGrant.from_scoped(%{
               scoped_grant
               | scope: Map.put(scoped_grant.scope, :endpoint_ref, "endpoint://google/gemini")
             })

    refute inspect(model_grant) =~ "credential"
    refute inspect(model_grant) =~ "api_key"
  end

  test "secret-bearing or incomplete inputs fail before authority persistence" do
    attrs = issue_attrs()

    assert {:error, :invalid_model_authority_input} =
             ModelAuthority.evaluate_and_persist(
               Map.put(attrs, :api_key, "sentinel-secret"),
               ModelInvocationPolicy.synapse_gemini_turn!()
             )

    assert {:error, :invalid_model_authority_input} =
             ModelAuthority.evaluate_and_persist(
               Map.delete(attrs, :fence_token),
               ModelInvocationPolicy.synapse_gemini_turn!()
             )

    assert Repo.get(AuthorityDecision, attrs.decision_ref) == nil
    assert Repo.get(ScopedGrantRecord, attrs.grant_ref) == nil
  end

  defp issue_attrs do
    %{
      session_ref: unique_ref("session"),
      decision_ref: unique_ref("decision"),
      grant_ref: unique_ref("grant"),
      tenant_ref: "tenant://acme",
      actor_ref: "actor://synapse/operator",
      subject_ref: "subject://synapse/run-1/turn-1",
      provider_family: "google_gemini",
      account_ref: "provider-account://tenant-acme/google-gemini/primary",
      model_ref: "gemini-2.5-flash",
      operation_ref: "operation://gemini/generate/run-1/turn-1",
      operation_class: "generate_content",
      context_ref: "context://outer-brain/run-1/turn-1/v1",
      context_digest: @context_digest,
      attempt_ref: "attempt://jido/run-1/turn-1/1",
      effect_ref: "effect://mezzanine/run-1/turn-1/model",
      fence_token: "fence://google-gemini/primary/generation-7",
      issued_at: @issued_at,
      expires_at: @expires_at
    }
  end

  defp unique_issue_refs(attrs) do
    attrs
    |> Map.put(:session_ref, unique_ref("session"))
    |> Map.put(:decision_ref, unique_ref("decision"))
    |> Map.put(:grant_ref, unique_ref("grant"))
  end

  defp grant_binding(grant), do: Map.take(Map.from_struct(grant), binding_fields())

  defp binding_fields do
    [
      :decision_ref,
      :input_digest,
      :policy_ref,
      :policy_version,
      :tenant_ref,
      :actor_ref,
      :subject_ref,
      :provider_family,
      :account_ref,
      :model_ref,
      :operation_ref,
      :operation_class,
      :context_ref,
      :context_digest,
      :attempt_ref,
      :effect_ref,
      :fence_token
    ]
  end

  defp unique_ref(kind), do: "#{kind}://citadel/#{System.unique_integer([:positive])}"
end
