defmodule Citadel.Governance.GrantControlDecisionTest do
  use ExUnit.Case, async: false

  alias Citadel.Governance.Repo
  alias Citadel.Governance.ToolEffectAuthority
  alias Citadel.GrantControlDecisionReceipt
  alias Citadel.PolicyPacks.ToolEffectPolicy

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

  test "database-time authority and deadline decision is durable and single-use" do
    {attrs, grant, binding} = persist_tool_grant!()
    receipt_ref = unique_ref("control-receipt")

    control = %{
      receipt_ref: receipt_ref,
      attempt_ref: attrs.attempt_ref,
      boundary_ref: "boundary://jido/codex-dispatch",
      deadline_at: DateTime.add(attrs.issued_at, 60, :second)
    }

    assert {:ok,
            %GrantControlDecisionReceipt{
              receipt_ref: ^receipt_ref,
              grant_ref: grant_ref,
              authority_decision_ref: decision_ref,
              attempt_ref: attempt_ref,
              result: "permitted",
              reason: "exact_authority_verified",
              grant_revision: 1,
              session_revision: 1,
              revocation_ref: nil
            } = receipt} =
             ToolEffectAuthority.decide_grant(grant.grant_ref, binding, control)

    assert grant_ref == grant.grant_ref
    assert decision_ref == grant.decision_ref
    assert attempt_ref == attrs.attempt_ref
    assert DateTime.compare(receipt.observed_at, attrs.issued_at) == :gt
    assert String.starts_with?(receipt.request_hash, "sha256:")
    assert String.starts_with?(GrantControlDecisionReceipt.digest(receipt), "sha256:")

    assert {:error, :grant_control_receipt_already_decided} =
             ToolEffectAuthority.decide_grant(grant.grant_ref, binding, control)

    readback_task =
      Task.async(fn -> ToolEffectAuthority.fetch_grant_control_receipt(receipt_ref) end)

    assert {:ok, ^receipt} = Task.await(readback_task)

    %{rows: [[stored]]} =
      Ecto.Adapters.SQL.query!(
        Repo,
        "SELECT row_to_json(r)::text FROM citadel_grant_control_receipts AS r " <>
          "WHERE receipt_ref = $1",
        [receipt_ref]
      )

    refute String.contains?(stored, attrs.provider_account_ref)
    refute String.contains?(stored, attrs.workspace_ref)
    refute String.contains?(stored, attrs.reviewed_content_digest)
  end

  test "a cached active grant cannot survive committed revocation or session closure" do
    {attrs, grant, binding} = persist_tool_grant!()
    assert {:ok, %{status: "active"}} = ToolEffectAuthority.fetch_grant(grant.grant_ref)

    revocation_ref = unique_ref("revocation")

    assert {:ok, %{status: "revoked"}} =
             ToolEffectAuthority.revoke_grant(grant.grant_ref, %{
               revocation_ref: revocation_ref,
               revoked_at: DateTime.add(attrs.issued_at, 10, :second),
               reason_ref: "reason://citadel/operator-revoked"
             })

    assert {:error,
            {:grant_control_denied,
             %GrantControlDecisionReceipt{
               result: "denied",
               reason: "grant_revoked",
               grant_revision: 2,
               revocation_ref: ^revocation_ref
             }}} =
             ToolEffectAuthority.decide_grant(grant.grant_ref, binding, %{
               receipt_ref: unique_ref("control-receipt"),
               attempt_ref: attrs.attempt_ref,
               boundary_ref: "boundary://jido/codex-dispatch",
               deadline_at: DateTime.add(attrs.issued_at, 60, :second)
             })

    {closed_attrs, closed_grant, closed_binding} = persist_tool_grant!()

    assert {:ok, %{status: "closed"}} =
             Citadel.Governance.DurableAuthority.close_session(
               closed_attrs.session_ref,
               1,
               %{
                 closed_at: DateTime.add(closed_attrs.issued_at, 10, :second),
                 reason_ref: "reason://citadel/authority-changed"
               }
             )

    assert {:error,
            {:grant_control_denied,
             %GrantControlDecisionReceipt{
               result: "denied",
               reason: "authority_session_closed",
               session_revision: 2
             }}} =
             ToolEffectAuthority.decide_grant(
               closed_grant.grant_ref,
               closed_binding,
               %{
                 receipt_ref: unique_ref("control-receipt"),
                 attempt_ref: closed_attrs.attempt_ref,
                 boundary_ref: "boundary://jido/codex-dispatch",
                 deadline_at: DateTime.add(closed_attrs.issued_at, 60, :second)
               }
             )
  end

  test "elapsed, over-grant, and mismatched deadline decisions fail closed with exact receipts" do
    {elapsed_attrs, elapsed_grant, elapsed_binding} = persist_tool_grant!()

    assert {:error,
            {:grant_control_denied,
             %GrantControlDecisionReceipt{
               result: "denied",
               reason: "deadline_elapsed"
             }}} =
             ToolEffectAuthority.decide_grant(
               elapsed_grant.grant_ref,
               elapsed_binding,
               %{
                 receipt_ref: unique_ref("control-receipt"),
                 attempt_ref: elapsed_attrs.attempt_ref,
                 boundary_ref: "boundary://jido/codex-dispatch",
                 deadline_at: DateTime.add(elapsed_attrs.issued_at, -1, :second)
               }
             )

    {over_attrs, over_grant, over_binding} = persist_tool_grant!()

    assert {:error,
            {:grant_control_denied,
             %GrantControlDecisionReceipt{
               result: "denied",
               reason: "deadline_exceeds_grant"
             }}} =
             ToolEffectAuthority.decide_grant(over_grant.grant_ref, over_binding, %{
               receipt_ref: unique_ref("control-receipt"),
               attempt_ref: over_attrs.attempt_ref,
               boundary_ref: "boundary://jido/codex-dispatch",
               deadline_at: DateTime.add(over_attrs.expires_at, 1, :microsecond)
             })

    {scope_attrs, scope_grant, scope_binding} = persist_tool_grant!()

    assert {:error,
            {:grant_control_denied,
             %GrantControlDecisionReceipt{
               result: "denied",
               reason: "exact_scope_mismatch"
             }}} =
             ToolEffectAuthority.decide_grant(
               scope_grant.grant_ref,
               %{scope_binding | target_ref: "target://workspace/reviewed/other.txt"},
               %{
                 receipt_ref: unique_ref("control-receipt"),
                 attempt_ref: scope_attrs.attempt_ref,
                 boundary_ref: "boundary://jido/codex-dispatch",
                 deadline_at: DateTime.add(scope_attrs.issued_at, 60, :second)
               }
             )
  end

  test "checkpoint identity cannot broaden attempt or retry authority" do
    {attrs, grant, binding} = persist_tool_grant!()

    assert {:error, :tool_effect_checkpoint_attempt_mismatch} =
             ToolEffectAuthority.decide_grant(grant.grant_ref, binding, %{
               receipt_ref: unique_ref("control-receipt"),
               attempt_ref: "attempt://jido/other",
               boundary_ref: "boundary://jido/codex-dispatch",
               deadline_at: DateTime.add(attrs.issued_at, 60, :second)
             })

    assert {:ok, _receipt} =
             ToolEffectAuthority.decide_grant(grant.grant_ref, binding, %{
               receipt_ref: unique_ref("control-receipt"),
               attempt_ref: attrs.attempt_ref,
               boundary_ref: "boundary://jido/codex-dispatch",
               deadline_at: DateTime.add(attrs.issued_at, 60, :second)
             })

    assert {:error, :grant_control_checkpoint_already_decided} =
             ToolEffectAuthority.decide_grant(grant.grant_ref, binding, %{
               receipt_ref: unique_ref("control-receipt"),
               attempt_ref: attrs.attempt_ref,
               boundary_ref: "boundary://jido/codex-dispatch",
               deadline_at: DateTime.add(attrs.issued_at, 60, :second)
             })
  end

  defp persist_tool_grant! do
    attrs = issue_attrs()
    policy = ToolEffectPolicy.synapse_codex_reviewed_write!()

    {:ok, input_digest} = ToolEffectAuthority.input_digest(attrs)

    {:ok, %{grant: grant}} =
      ToolEffectAuthority.evaluate_and_persist(attrs, policy)

    binding =
      attrs
      |> Map.drop([:session_ref, :grant_ref, :issued_at, :expires_at])
      |> Map.merge(%{
        input_digest: input_digest,
        policy_ref: policy.artifact_ref,
        policy_version: policy.policy_version
      })

    {attrs, grant, binding}
  end

  defp issue_attrs do
    issued_at = DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:microsecond)

    %{
      session_ref: unique_ref("authority-session"),
      decision_ref: unique_ref("decision"),
      grant_ref: unique_ref("grant"),
      tenant_ref: "tenant://acme",
      actor_ref: "actor://synapse/operator",
      subject_ref: unique_ref("subject"),
      provider_family: "codex",
      provider_account_ref: "provider-account://tenant-acme/codex/primary",
      credential_lease_ref: unique_ref("credential-lease"),
      credential_generation: 7,
      managed_session_ref: unique_ref("managed-session"),
      session_generation: 3,
      review_ref: unique_ref("review"),
      workspace_policy: "isolated_disposable_workspace",
      workspace_ref: unique_ref("workspace"),
      workspace_root_digest: @workspace_digest,
      relative_path: "reviewed/result.txt",
      operation_ref: unique_ref("operation"),
      operation_class: "create_or_replace",
      capability_id: "codex.session.turn",
      reviewed_content_digest: @content_digest,
      target_ref: "target://workspace/reviewed/result.txt",
      attempt_ref: unique_ref("attempt"),
      effect_ref: unique_ref("effect"),
      issued_at: issued_at,
      expires_at: DateTime.add(issued_at, 180, :second)
    }
  end

  defp unique_ref(kind), do: "#{kind}://citadel/#{System.unique_integer([:positive])}"
end
