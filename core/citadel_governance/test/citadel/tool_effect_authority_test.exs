defmodule Citadel.Governance.ToolEffectAuthorityTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Citadel.Governance.DurableSchemas.AuthorityDecision
  alias Citadel.Governance.DurableSchemas.ScopedGrantRecord
  alias Citadel.Governance.DurableAuthority
  alias Citadel.Governance.ModelAuthority
  alias Citadel.Governance.Repo
  alias Citadel.Governance.ToolEffectAuthority
  alias Citadel.GrantEnforcementReceipt
  alias Citadel.GrantVerificationError
  alias Citadel.PolicyPacks.ModelInvocationPolicy
  alias Citadel.PolicyPacks.ToolEffectPolicy
  alias Citadel.ScopedGrant

  @issued_at ~U[2026-07-27 12:00:00.000000Z]
  @expires_at ~U[2026-07-27 12:03:00.000000Z]
  @workspace_digest "sha256:" <> String.duplicate("a", 64)
  @content_digest "sha256:" <> String.duplicate("b", 64)

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

  test "persists one exact permit-with-review grant and reconstructs it without a second contract" do
    attrs = issue_attrs()
    policy = ToolEffectPolicy.synapse_codex_reviewed_write!()
    assert {:ok, input_digest} = ToolEffectAuthority.input_digest(attrs)

    assert {:ok, %{result: :permit_with_review, decision: decision, grant: grant}} =
             ToolEffectAuthority.evaluate_and_persist(attrs, policy)

    assert %ScopedGrant{
             decision_ref: decision_ref,
             capability_id: "codex.session.turn",
             input_snapshot_hash: ^input_digest,
             status: "active"
           } = grant

    assert decision_ref == attrs.decision_ref
    assert decision.decision_payload["decision_mode"] == "permit_with_review"
    assert decision.decision_payload["input_snapshot"]["review_ref"] == attrs.review_ref
    assert grant.scope["provider_account_ref"] == attrs.provider_account_ref
    assert grant.scope["credential_generation"] == attrs.credential_generation
    assert grant.scope["managed_session_ref"] == attrs.managed_session_ref
    assert grant.scope["session_generation"] == attrs.session_generation
    assert grant.scope["workspace_ref"] == attrs.workspace_ref
    assert grant.scope["workspace_root_digest"] == @workspace_digest
    assert grant.scope["relative_path"] == attrs.relative_path
    assert grant.scope["operation_class"] == "create_or_replace"
    assert grant.scope["reviewed_content_digest"] == @content_digest
    assert grant.scope["target_ref"] == attrs.target_ref

    assert Enum.any?(grant.obligations, &(&1["type"] == "require_authorized_review"))
    assert Enum.any?(grant.obligations, &(&1["type"] == "cleanup_isolated_materialization"))

    assert Repo.aggregate(
             from(d in AuthorityDecision, where: d.decision_ref == ^attrs.decision_ref),
             :count
           ) == 1

    assert Repo.aggregate(
             from(g in ScopedGrantRecord, where: g.grant_ref == ^attrs.grant_ref),
             :count
           ) == 1

    assert {:ok, ^grant} = ToolEffectAuthority.fetch_grant(attrs.grant_ref)

    assert :ok =
             ToolEffectAuthority.verify_grant(attrs.grant_ref, grant_binding(grant), @issued_at)

    assert {:ok, %{result: :permit_with_review, decision: ^decision, grant: ^grant}} =
             ToolEffectAuthority.evaluate_and_persist(attrs, policy)

    receipt =
      GrantEnforcementReceipt.new!(%{
        receipt_ref: unique_ref("receipt"),
        grant_ref: grant.grant_ref,
        decision_ref: grant.decision_ref,
        effect_ref: grant.effect_ref,
        operation_ref: grant.operation_ref,
        attempt_ref: attrs.attempt_ref,
        boundary_ref: "boundary://jido/codex-materializer",
        result: "enforced",
        enforced_at: @issued_at
      })

    assert receipt.grant_ref == grant.grant_ref
    assert receipt.attempt_ref == attrs.attempt_ref
  end

  test "verification rejects drift across every decision, account, generation, review, and target binding" do
    attrs = issue_attrs()

    assert {:ok, %{grant: grant}} =
             ToolEffectAuthority.evaluate_and_persist(
               attrs,
               ToolEffectPolicy.synapse_codex_reviewed_write!()
             )

    mismatches = [
      decision_ref: unique_ref("decision-other"),
      input_digest: "sha256:" <> String.duplicate("c", 64),
      policy_ref: "policy-artifact://citadel/other/v1",
      policy_version: 2,
      tenant_ref: "tenant://other",
      actor_ref: "actor://other",
      subject_ref: "subject://other",
      provider_family: "claude",
      provider_account_ref: "provider-account://other",
      credential_lease_ref: "credential-lease://other",
      credential_generation: 8,
      managed_session_ref: "session://asm/other",
      session_generation: 4,
      review_ref: "review://mezzanine/other",
      workspace_policy: "caller_workspace",
      workspace_ref: "workspace://mezzanine/other",
      workspace_root_digest: "sha256:" <> String.duplicate("d", 64),
      relative_path: "reviewed/other.txt",
      operation_ref: "operation://codex/other",
      operation_class: "delete",
      capability_id: "model_inference",
      reviewed_content_digest: "sha256:" <> String.duplicate("e", 64),
      target_ref: "target://workspace/reviewed/other.txt",
      attempt_ref: "attempt://jido/other",
      effect_ref: "effect://mezzanine/other"
    ]

    Enum.each(mismatches, fn {field, value} ->
      assert {:error,
              %GrantVerificationError{
                category: :scope_mismatch,
                reason: :exact_scope_mismatch
              }} =
               ToolEffectAuthority.verify_grant(
                 grant.grant_ref,
                 Map.put(grant_binding(grant), field, value),
                 @issued_at
               )
    end)
  end

  test "wildcards, traversal, broad operations, and overlong grants persist denials without grants" do
    policy = ToolEffectPolicy.synapse_codex_reviewed_write!()

    for {field, value, reason} <- [
          {:workspace_ref, "workspace://*", :workspace_not_allowed},
          {:relative_path, "../reviewed.txt", :relative_path_not_allowed},
          {:relative_path, "reviewed/*.txt", :relative_path_not_allowed},
          {:operation_class, "*", :operation_not_allowed},
          {:provider_account_ref, "provider-account://*", :provider_account_not_allowed},
          {:review_ref, "review://mezzanine/*", :review_not_allowed},
          {:operation_ref, "operation://codex/*", :operation_ref_not_allowed},
          {:target_ref, "target://*", :target_not_allowed},
          {:expires_at, DateTime.add(@issued_at, 301, :second), :grant_ttl_not_allowed}
        ] do
      attrs = issue_attrs() |> unique_issue_refs() |> Map.put(field, value)

      assert {:ok, %{result: :denied, reason: ^reason, decision: decision}} =
               ToolEffectAuthority.evaluate_and_persist(attrs, policy)

      assert decision.result == "denied"
      assert decision.decision_payload["reason"] == Atom.to_string(reason)
      assert Repo.get(ScopedGrantRecord, attrs.grant_ref) == nil
    end
  end

  test "expiry and committed revocation cannot race into a successful verification" do
    attrs = issue_attrs()

    assert {:ok, %{grant: grant}} =
             ToolEffectAuthority.evaluate_and_persist(
               attrs,
               ToolEffectPolicy.synapse_codex_reviewed_write!()
             )

    assert {:error, %GrantVerificationError{category: :expired}} =
             ToolEffectAuthority.verify_grant(grant.grant_ref, grant_binding(grant), @expires_at)

    revoked_at = DateTime.add(@issued_at, 30, :second)

    assert {:ok, %ScopedGrant{status: "revoked"}} =
             ToolEffectAuthority.revoke_grant(grant.grant_ref, %{
               revocation_ref: unique_ref("revocation"),
               revoked_at: revoked_at,
               reason_ref: "reason://citadel/codex-session-cleanup"
             })

    for _attempt <- 1..10 do
      assert {:error, %GrantVerificationError{category: :revoked}} =
               ToolEffectAuthority.verify_grant(grant.grant_ref, grant_binding(grant), revoked_at)
    end
  end

  test "session cleanup revokes its exact tool grant before any later verification" do
    attrs = issue_attrs()

    assert {:ok, %{grant: grant}} =
             ToolEffectAuthority.evaluate_and_persist(
               attrs,
               ToolEffectPolicy.synapse_codex_reviewed_write!()
             )

    closed_at = DateTime.add(@issued_at, 30, :second)

    assert {:ok, session} =
             DurableAuthority.close_session(attrs.session_ref, 1, %{
               closed_at: closed_at,
               reason_ref: "reason://citadel/codex-session-cleanup"
             })

    assert session.status == "closed"

    assert {:ok, %ScopedGrant{status: "revoked"}} =
             ToolEffectAuthority.fetch_grant(grant.grant_ref)

    assert {:error,
            %GrantVerificationError{
              category: :revoked,
              reason: :decision_session_closed
            }} =
             ToolEffectAuthority.verify_grant(
               grant.grant_ref,
               grant_binding(grant),
               closed_at
             )
  end

  test "the tool facade cannot verify or revoke a model authority grant" do
    attrs = issue_attrs()

    assert {:ok, %{grant: tool_grant}} =
             ToolEffectAuthority.evaluate_and_persist(
               attrs,
               ToolEffectPolicy.synapse_codex_reviewed_write!()
             )

    assert {:ok, %{grant: model_grant}} =
             ModelAuthority.evaluate_and_persist(
               model_issue_attrs(),
               ModelInvocationPolicy.synapse_gemini_turn!()
             )

    assert {:error, :invalid_tool_effect_grant} =
             ToolEffectAuthority.fetch_grant(model_grant.grant_ref)

    assert {:error,
            %GrantVerificationError{
              category: :invalid,
              reason: :invalid_reconstructed_tool_effect_grant
            }} =
             ToolEffectAuthority.verify_grant(
               model_grant.grant_ref,
               grant_binding(tool_grant),
               @issued_at
             )

    assert {:error, :invalid_tool_effect_grant} =
             ToolEffectAuthority.revoke_grant(model_grant.grant_ref, %{
               revocation_ref: unique_ref("revocation"),
               revoked_at: DateTime.add(@issued_at, 30, :second),
               reason_ref: "reason://citadel/tool-session-cleanup"
             })

    assert {:ok, %{status: "active"}} = ModelAuthority.fetch_grant(model_grant.grant_ref)
  end

  test "secret-bearing and incomplete authority inputs fail before persistence" do
    attrs = issue_attrs()

    assert {:error, :invalid_tool_effect_authority_input} =
             ToolEffectAuthority.evaluate_and_persist(
               Map.put(attrs, :api_key, "sentinel-secret"),
               ToolEffectPolicy.synapse_codex_reviewed_write!()
             )

    assert {:error, :invalid_tool_effect_authority_input} =
             ToolEffectAuthority.evaluate_and_persist(
               Map.delete(attrs, :credential_generation),
               ToolEffectPolicy.synapse_codex_reviewed_write!()
             )

    assert Repo.get(AuthorityDecision, attrs.decision_ref) == nil
    assert Repo.get(ScopedGrantRecord, attrs.grant_ref) == nil
  end

  defp issue_attrs do
    %{
      session_ref: unique_ref("authority-session"),
      decision_ref: unique_ref("decision"),
      grant_ref: unique_ref("grant"),
      tenant_ref: "tenant://acme",
      actor_ref: "actor://synapse/operator",
      subject_ref: "subject://synapse/run-2/effect-1",
      provider_family: "codex",
      provider_account_ref: "provider-account://tenant-acme/codex/primary",
      credential_lease_ref: "credential-lease://jido/codex/run-2/effect-1",
      credential_generation: 7,
      managed_session_ref: "session://asm/codex/run-2/effect-1",
      session_generation: 3,
      review_ref: "review://mezzanine/run-2/effect-1/approved",
      workspace_policy: "isolated_disposable_workspace",
      workspace_ref: "workspace://mezzanine/run-2/effect-1",
      workspace_root_digest: @workspace_digest,
      relative_path: "reviewed/result.txt",
      operation_ref: "operation://codex/run-2/effect-1/create-or-replace",
      operation_class: "create_or_replace",
      capability_id: "codex.session.turn",
      reviewed_content_digest: @content_digest,
      target_ref: "target://workspace/reviewed/result.txt",
      attempt_ref: "attempt://jido/run-2/effect-1/1",
      effect_ref: "effect://mezzanine/run-2/effect-1",
      issued_at: @issued_at,
      expires_at: @expires_at
    }
  end

  defp unique_issue_refs(attrs) do
    attrs
    |> Map.put(:session_ref, unique_ref("authority-session"))
    |> Map.put(:decision_ref, unique_ref("decision"))
    |> Map.put(:grant_ref, unique_ref("grant"))
  end

  defp model_issue_attrs do
    %{
      session_ref: unique_ref("model-session"),
      decision_ref: unique_ref("model-decision"),
      grant_ref: unique_ref("model-grant"),
      tenant_ref: "tenant://acme",
      actor_ref: "actor://synapse/operator",
      subject_ref: "subject://synapse/run-2/model",
      provider_family: "gemini",
      account_ref: "provider-account://tenant-acme/gemini/primary",
      model_ref: "gemini-2.5-flash",
      operation_ref: "operation://gemini/run-2/generate",
      operation_class: "generate_content",
      context_ref: "context://outer-brain/run-2/model",
      context_digest: "sha256:" <> String.duplicate("c", 64),
      attempt_ref: "attempt://jido/run-2/model/1",
      effect_ref: "effect://mezzanine/run-2/model",
      fence_token: "fence://gemini/primary/generation-7",
      issued_at: @issued_at,
      expires_at: DateTime.add(@issued_at, 60, :second)
    }
  end

  defp grant_binding(grant) do
    %{
      decision_ref: grant.scope["authority_decision_ref"],
      input_digest: grant.scope["input_digest"],
      policy_ref: grant.scope["policy_ref"],
      policy_version: grant.scope["policy_version"],
      tenant_ref: grant.tenant_ref,
      actor_ref: grant.actor_ref,
      subject_ref: grant.subject_ref,
      provider_family: grant.scope["provider_family"],
      provider_account_ref: grant.scope["provider_account_ref"],
      credential_lease_ref: grant.scope["credential_lease_ref"],
      credential_generation: grant.scope["credential_generation"],
      managed_session_ref: grant.scope["managed_session_ref"],
      session_generation: grant.scope["session_generation"],
      review_ref: grant.scope["review_ref"],
      workspace_policy: grant.scope["workspace_policy"],
      workspace_ref: grant.scope["workspace_ref"],
      workspace_root_digest: grant.scope["workspace_root_digest"],
      relative_path: grant.scope["relative_path"],
      operation_ref: grant.operation_ref,
      operation_class: grant.scope["operation_class"],
      capability_id: grant.capability_id,
      reviewed_content_digest: grant.scope["reviewed_content_digest"],
      target_ref: grant.scope["target_ref"],
      attempt_ref: grant.scope["attempt_ref"],
      effect_ref: grant.effect_ref
    }
  end

  defp unique_ref(kind), do: "#{kind}://citadel/#{System.unique_integer([:positive])}"
end
