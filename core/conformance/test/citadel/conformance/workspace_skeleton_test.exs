defmodule Citadel.Conformance.WorkspaceSkeletonTest do
  use ExUnit.Case, async: true

  test "tracks the packet-defined seam and wave posture" do
    assert Citadel.ContractCore.manifest().status == :wave_2_seam_frozen
    assert Citadel.AuthorityContract.manifest().status == :phase_4_authority_packet_hardened
    assert Citadel.ExecutionGovernanceContract.manifest().status == :wave_10_data_layer_frozen
    assert Citadel.AuthorityContract.packet_name() == "Citadel.AuthorityPacketV2.v1"
    assert Citadel.ExecutionGovernanceContract.packet_name() == "ExecutionGovernance.v1"
    assert Citadel.AuthorityContract.extensions_namespaces() == ["citadel"]
    assert Citadel.ExecutionGovernanceContract.extensions_namespaces() == ["citadel"]
    assert :canonical_json_hash in Citadel.AuthorityContract.required_fields()

    assert Citadel.AuthorityContract.authority_packet_module() ==
             Citadel.AuthorityContract.AuthorityPacket.V2

    assert Citadel.AuthorityContract.authority_decision_module() ==
             Citadel.AuthorityContract.AuthorityDecision.V1

    assert Citadel.AuthorityContract.rejection_envelope_module() ==
             Citadel.AuthorityContract.RejectionEnvelope.V1

    assert Citadel.AuthorityContract.operator_recovery_action_module() ==
             Citadel.AuthorityContract.OperatorRecoveryAction.V1

    assert :execution_governance_id in Citadel.ExecutionGovernanceContract.required_fields()
    assert Citadel.ObservabilityContract.telemetry_prefix() == [:citadel]

    assert Citadel.PolicyPacks.selection_inputs() == [
             :tenant_id,
             :scope_kind,
             :environment,
             :policy_epoch
           ]

    assert Citadel.PolicyPacks.stable_selection_ordering() == :priority_desc_then_pack_id_asc
    assert Citadel.Governance.shared_contract_strategy() == :higher_order_shared_contracts_only

    assert Citadel.Governance.authority_packet_module() ==
             Citadel.AuthorityContract.AuthorityDecision.V1

    assert Citadel.Governance.invocation_request_module() == Citadel.InvocationRequest.V2
    assert Citadel.Governance.execution_governance_module() == Citadel.ExecutionGovernance.V1
    assert Citadel.Governance.structured_ingress_posture() == :structured_only

    assert Citadel.Governance.shared_lineage_contracts() == [
             Jido.Integration.V2.SubjectRef,
             Jido.Integration.V2.EvidenceRef,
             Jido.Integration.V2.GovernanceRef,
             Jido.Integration.V2.ReviewProjection,
             Jido.Integration.V2.DerivedStateAttachment
           ]

    assert Citadel.Kernel.manifest().package == :citadel_kernel

    assert Citadel.InvocationBridge.shared_contract_strategy() ==
             :citadel_invocation_request_entrypoint

    assert Citadel.InvocationBridge.supported_invocation_request_schema_versions() == [2]

    assert_raise ArgumentError, fn ->
      Citadel.InvocationBridge.ensure_supported_invocation_request_schema_version!(1)
    end

    assert Citadel.Apps.HostSurfaceHarness.manifest().status == :wave_7_host_surface_proof
    assert Citadel.Conformance.manifest().status == :wave_7_black_box_conformance

    assert Citadel.Conformance.manifest().external_dependencies == [
             :jido_integration_contracts
           ]
  end
end
