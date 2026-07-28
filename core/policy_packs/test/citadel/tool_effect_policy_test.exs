defmodule Citadel.PolicyPacks.ToolEffectPolicyTest do
  use ExUnit.Case, async: true

  alias Citadel.PolicyPacks.ToolEffectPolicy

  @issued_at ~U[2026-07-27 12:00:00Z]

  test "release artifact admits only the reviewed Codex named-file operation" do
    policy = ToolEffectPolicy.synapse_codex_reviewed_write!()

    assert policy.source_digest == ToolEffectPolicy.source_digest(ToolEffectPolicy.source(policy))
    assert :permit_with_review = ToolEffectPolicy.evaluate(policy, input())

    for {field, value, reason} <- [
          {:provider_family, "claude", :provider_not_allowed},
          {:capability_id, "model_inference", :capability_not_allowed},
          {:workspace_policy, "caller_workspace", :workspace_policy_not_allowed},
          {:operation_class, "*", :operation_not_allowed},
          {:provider_account_ref, "provider-account://*", :provider_account_not_allowed},
          {:credential_lease_ref, "credential-lease://*", :credential_lease_not_allowed},
          {:managed_session_ref, "session://asm/*", :managed_session_not_allowed},
          {:review_ref, "review://mezzanine/*", :review_not_allowed},
          {:workspace_ref, "workspace://*", :workspace_not_allowed},
          {:relative_path, "../reviewed.txt", :relative_path_not_allowed},
          {:relative_path, "reviewed-*.txt", :relative_path_not_allowed},
          {:operation_ref, "operation://codex/*", :operation_ref_not_allowed},
          {:target_ref, "target://*", :target_not_allowed},
          {:attempt_ref, "attempt://jido/*", :attempt_not_allowed},
          {:effect_ref, "effect://mezzanine/*", :effect_not_allowed},
          {:expires_at, DateTime.add(@issued_at, 301, :second), :grant_ttl_not_allowed},
          {:expires_at, DateTime.add(@issued_at, 300_000_001, :microsecond),
           :grant_ttl_not_allowed}
        ] do
      assert {:denied, ^reason} =
               ToolEffectPolicy.evaluate(policy, Map.put(input(), field, value))
    end
  end

  test "artifact reconstruction rejects source drift" do
    policy = ToolEffectPolicy.synapse_codex_reviewed_write!()

    assert_raise ArgumentError, ~r/source digest mismatch/, fn ->
      policy
      |> ToolEffectPolicy.dump()
      |> Map.put(:allowed_operations, ["*"])
      |> ToolEffectPolicy.new!()
    end
  end

  defp input do
    %{
      provider_family: "codex",
      capability_id: "codex.session.turn",
      workspace_policy: "isolated_disposable_workspace",
      operation_class: "create_or_replace",
      provider_account_ref: "provider-account://tenant-acme/codex/primary",
      credential_lease_ref: "credential-lease://jido/codex/effect-1",
      managed_session_ref: "session://asm/codex/effect-1",
      review_ref: "review://mezzanine/effect-1/approved",
      workspace_ref: "workspace://mezzanine/effect-1",
      relative_path: "reviewed/result.txt",
      operation_ref: "operation://codex/effect-1/create-or-replace",
      target_ref: "target://workspace/reviewed/result.txt",
      attempt_ref: "attempt://jido/effect-1/1",
      effect_ref: "effect://mezzanine/effect-1",
      issued_at: @issued_at,
      expires_at: DateTime.add(@issued_at, 180, :second)
    }
  end
end
