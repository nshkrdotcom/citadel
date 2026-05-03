defmodule Citadel.AuthorityContract.OperatorRecoveryAction.V1Test do
  use ExUnit.Case, async: true

  alias Citadel.AuthorityContract
  alias Citadel.AuthorityContract.OperatorRecoveryAction.V1

  test "normalizes authorized operator recovery actions" do
    action =
      sample_attrs()
      |> Map.put(:safe_action_class, "pause_workflow")
      |> V1.new!()

    assert AuthorityContract.operator_recovery_action_module() == V1
    assert action.safe_action_class == :pause_workflow
    assert action.requested_at == "2026-04-18T10:00:00Z"
    assert :retry_workflow in V1.safe_action_classes()
    assert :replan_workflow in V1.safe_action_classes()
  end

  test "fails closed when the safe action class is not whitelisted" do
    assert_raise ArgumentError, fn ->
      sample_attrs()
      |> Map.put(:safe_action_class, "delete_payloads")
      |> V1.new!()
    end
  end

  defp sample_attrs do
    %{
      contract_name: "Citadel.OperatorRecoveryAction.v1",
      contract_version: "1.0.0",
      tenant_ref: "tenant-1",
      installation_ref: "installation-1",
      workspace_ref: "workspace-1",
      project_ref: "project-1",
      environment_ref: "dev",
      principal_ref: "principal-1",
      operator_ref: "operator-1",
      action_ref: "operator-action-1",
      target_ref: "workflow-1",
      resource_ref: "resource-1",
      authority_packet_ref: "authpkt-1",
      permission_decision_ref: "decision-1",
      idempotency_key: "idempotency-1",
      trace_id: "trace-1",
      correlation_id: "correlation-1",
      release_manifest_ref: "phase4-v6-milestone4-authority-packet-rejection-hardening",
      safe_action_class: :retry_with_authority,
      approval_ref: "approval-1",
      operator_reason: "Retry with refreshed authority after stale revision rejection.",
      audit_ref: "audit-1",
      requested_at: "2026-04-18T10:00:00Z",
      metadata: %{"rejection_id" => "reject-1"}
    }
  end
end
