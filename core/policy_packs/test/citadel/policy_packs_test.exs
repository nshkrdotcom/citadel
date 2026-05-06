defmodule Citadel.PolicyPacksTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Citadel.PolicyPacks
  alias Citadel.PolicyPacks.ExecutionPolicy
  alias Citadel.PolicyPacks.GuardrailChainPolicy
  alias Citadel.PolicyPacks.PolicyPack
  alias Citadel.PolicyPacks.PromptVersionPolicy
  alias Citadel.PolicyPacks.Selection

  test "selects the highest-priority matching pack" do
    selection =
      PolicyPacks.select_profile!(
        [
          default_pack(),
          org_pack(priority: 20),
          org_pack(priority: 50, policy_version: "policy-2026-04-10")
        ],
        %{tenant_id: "tenant-1", scope_kind: "project", environment: "prod"}
      )

    assert %Selection{} = selection
    assert selection.pack_id == "tenant-prod-50"
    assert selection.policy_version == "policy-2026-04-10"
    assert selection.profiles.boundary_class == "workspace_session"
  end

  test "falls back to the explicit default pack when nothing else matches" do
    selection =
      PolicyPacks.select_profile!(
        [
          org_pack(),
          default_pack()
        ],
        %{tenant_id: "other-tenant", scope_kind: "workspace", environment: "dev"}
      )

    assert selection.pack_id == "default"
    assert selection.profiles.trust_profile == "baseline"
  end

  property "selection is deterministic regardless of pack order" do
    packs = [
      default_pack(),
      org_pack(priority: 10, pack_id: "tenant-prod-10"),
      org_pack(priority: 30, pack_id: "tenant-prod-30")
    ]

    orders = [
      [0, 1, 2],
      [0, 2, 1],
      [1, 0, 2],
      [1, 2, 0],
      [2, 0, 1],
      [2, 1, 0]
    ]

    check all(order <- StreamData.member_of(orders)) do
      ordered_packs = Enum.map(order, &Enum.at(packs, &1))

      selection =
        PolicyPacks.select_profile!(
          ordered_packs,
          %{tenant_id: "tenant-1", scope_kind: "project", environment: "prod"}
        )

      assert selection.pack_id == "tenant-prod-30"
    end
  end

  test "normalizes packs into explicit values" do
    pack = default_pack() |> PolicyPack.new!()

    assert pack.selector.default?

    assert pack.rejection_policy.denial_audit_reason_codes == [
             "policy_denied",
             "approval_missing"
           ]
  end

  test "defines a coding-ops standard pack with explicit execution policy" do
    pack = PolicyPacks.coding_ops_standard_pack!()

    assert %PolicyPack{} = pack
    assert pack.pack_id == "coding-ops-standard"
    assert pack.profiles.approval_profile == "manual"
    assert pack.profiles.egress_profile == "restricted"
    assert %ExecutionPolicy{} = pack.execution_policy

    assert pack.execution_policy.minimum_sandbox_level == "strict"
    assert pack.execution_policy.maximum_egress == "restricted"
    assert pack.execution_policy.approval_mode == "manual"
    assert "codex.session.turn" in pack.execution_policy.allowed_operations
    assert "write_patch" in pack.execution_policy.allowed_tools
    assert "repo_write" in pack.execution_policy.command_classes
    assert pack.execution_policy.workspace_mutability == "read_write"
    assert pack.execution_policy.placement_intents == ["host_local", "remote_workspace"]
    assert %PromptVersionPolicy{} = pack.prompt_version_policy
    assert %GuardrailChainPolicy{} = pack.guardrail_chain_policy

    assert pack.prompt_version_policy.allowed_prompt_refs == [
             "prompt://coding-ops/standard/system"
           ]

    assert pack.guardrail_chain_policy.guard_chain_ref ==
             "guard-chain://coding-ops/standard/default"

    assert pack.guardrail_chain_policy.fail_closed?
  end

  test "policy packs preserve prompt and guard policy through selection dumps" do
    pack = PolicyPacks.coding_ops_standard_pack!()

    assert %Selection{} =
             selection =
             PolicyPacks.select_profile!(
               [pack],
               %{tenant_id: "tenant-1", scope_kind: "project", environment: "prod"}
             )

    dumped = Selection.dump(selection)

    assert dumped.prompt_version_policy.allowed_prompt_refs == [
             "prompt://coding-ops/standard/system"
           ]

    assert dumped.guardrail_chain_policy.redaction_posture_floor == "partial"
  end

  defp default_pack do
    %{
      pack_id: "default",
      policy_version: "policy-2026-04-09",
      policy_epoch: 7,
      priority: 0,
      selector: %{
        tenant_ids: [],
        scope_kinds: [],
        environments: [],
        default?: true,
        extensions: %{}
      },
      profiles: %{
        trust_profile: "baseline",
        approval_profile: "standard_approval",
        egress_profile: "restricted",
        workspace_profile: "default_workspace",
        resource_profile: "standard",
        boundary_class: "workspace_session",
        extensions: %{}
      },
      rejection_policy: %{
        denial_audit_reason_codes: ["policy_denied", "approval_missing"],
        derived_state_reason_codes: ["planning_failed"],
        runtime_change_reason_codes: ["scope_unavailable", "service_hidden", "boundary_stale"],
        governance_change_reason_codes: ["approval_missing"],
        extensions: %{}
      },
      extensions: %{}
    }
  end

  defp org_pack(overrides \\ []) do
    default_pack()
    |> Map.merge(%{
      pack_id:
        Keyword.get(overrides, :pack_id, "tenant-prod-#{Keyword.get(overrides, :priority, 30)}"),
      policy_version: Keyword.get(overrides, :policy_version, "policy-2026-04-09"),
      priority: Keyword.get(overrides, :priority, 30),
      selector: %{
        tenant_ids: ["tenant-1"],
        scope_kinds: ["project"],
        environments: ["prod"],
        default?: false,
        extensions: %{}
      },
      profiles: %{
        trust_profile: "trusted_operator",
        approval_profile: "approval_required",
        egress_profile: "restricted",
        workspace_profile: "project_workspace",
        resource_profile: "standard",
        boundary_class: "workspace_session",
        extensions: %{}
      }
    })
  end
end
