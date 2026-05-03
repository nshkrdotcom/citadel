defmodule Citadel.AuthorityContract.RejectionEnvelope.V1Test do
  use ExUnit.Case, async: true

  alias Citadel.AuthorityContract
  alias Citadel.AuthorityContract.RejectionEnvelope.V1

  test "normalizes Phase 4 rejection taxonomy without creating atoms from strings" do
    envelope =
      sample_attrs()
      |> Map.merge(%{
        rejection_class: "policy_error",
        retry_posture: "after_operator_action",
        operator_visibility: "full_operator",
        status: "quarantined"
      })
      |> V1.new!()

    assert AuthorityContract.rejection_envelope_module() == V1
    assert envelope.rejection_class == :policy_error
    assert envelope.retry_posture == :after_operator_action
    assert envelope.operator_visibility == :full_operator
    assert envelope.status == :quarantined
  end

  test "fails closed on missing actor and unknown rejection class" do
    assert_raise ArgumentError, fn ->
      sample_attrs()
      |> Map.delete(:principal_ref)
      |> V1.new!()
    end

    assert_raise ArgumentError, fn ->
      sample_attrs()
      |> Map.put(:rejection_class, "invented")
      |> V1.new!()
    end
  end

  defp sample_attrs do
    %{
      contract_name: "Platform.RejectionEnvelope.v1",
      contract_version: "1.0.0",
      rejection_id: "reject-1",
      tenant_ref: "tenant-1",
      installation_ref: "installation-1",
      workspace_ref: "workspace-1",
      project_ref: "project-1",
      environment_ref: "dev",
      principal_ref: "principal-1",
      resource_ref: "resource-1",
      authority_packet_ref: "authpkt-1",
      permission_decision_ref: "decision-1",
      idempotency_key: "idempotency-1",
      trace_id: "trace-1",
      correlation_id: "correlation-1",
      release_manifest_ref: "phase4-v6-milestone4-authority-packet-rejection-hardening",
      rejection_code: "stale_revision",
      rejection_class: :policy_error,
      retry_posture: :after_input_change,
      operator_visibility: :summary,
      http_status_or_rpc_status: "409",
      status: :rejected,
      safe_action_code: "refresh_revision_and_retry",
      message: "Installation revision is stale.",
      details: %{"expected_revision" => 12, "actual_revision" => 11},
      redaction: %{"operator_fields" => ["message"], "public_fields" => ["rejection_code"]}
    }
  end
end
