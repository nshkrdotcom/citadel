defmodule Citadel.AuthorityContract do
  @moduledoc """
  Packet-aligned ownership surface for the shared Brain authority packet.
  """

  alias Citadel.AuthorityContract.AuthorityDecision.V1, as: AuthorityDecisionV1
  alias Citadel.AuthorityContract.AuthorityPacket.V2, as: AuthorityPacketV2

  alias Citadel.AuthorityContract.AuthorityTenantPropagation.V1,
    as: AuthorityTenantPropagationV1

  alias Citadel.AuthorityContract.ErrorTaxonomy.V1, as: ErrorTaxonomyV1
  alias Citadel.AuthorityContract.InstallationRevisionEpoch.V1, as: InstallationRevisionEpochV1
  alias Citadel.AuthorityContract.LeaseRevocation.V1, as: LeaseRevocationV1
  alias Citadel.AuthorityContract.OperatorRecoveryAction.V1, as: OperatorRecoveryActionV1
  alias Citadel.AuthorityContract.PersistencePosture
  alias Citadel.AuthorityContract.RejectionEnvelope.V1, as: RejectionEnvelopeV1
  alias Citadel.OperatorWorkflowSignalAuthorityV1

  @required_fields AuthorityPacketV2.required_fields()

  @manifest %{
    package: :citadel_authority_contract,
    layer: :core,
    status: :phase_4_authority_packet_hardened,
    owns: [
      :authority_decision_v1,
      :authority_packet_v2,
      :authority_tenant_propagation_v1,
      :operator_recovery_action_v1,
      :operator_workflow_signal_authority_v1,
      :packet_versioning,
      :platform_error_taxonomy_v1,
      :platform_installation_revision_epoch_v1,
      :platform_lease_revocation_v1,
      :platform_rejection_envelope_v1,
      :contract_fixtures
    ],
    internal_dependencies: [:citadel_contract_core],
    external_dependencies: [:ground_plane_persistence_policy]
  }

  @extensions_namespaces AuthorityPacketV2.extensions_namespaces()

  @spec required_fields() :: [atom()]
  def required_fields, do: @required_fields

  @spec authority_decision_module() :: module()
  def authority_decision_module, do: AuthorityDecisionV1

  @spec authority_packet_module() :: module()
  def authority_packet_module, do: AuthorityPacketV2

  @spec authority_tenant_propagation_module() :: module()
  def authority_tenant_propagation_module, do: AuthorityTenantPropagationV1

  @spec rejection_envelope_module() :: module()
  def rejection_envelope_module, do: RejectionEnvelopeV1

  @spec error_taxonomy_module() :: module()
  def error_taxonomy_module, do: ErrorTaxonomyV1

  @spec installation_revision_epoch_module() :: module()
  def installation_revision_epoch_module, do: InstallationRevisionEpochV1

  @spec lease_revocation_module() :: module()
  def lease_revocation_module, do: LeaseRevocationV1

  @spec operator_recovery_action_module() :: module()
  def operator_recovery_action_module, do: OperatorRecoveryActionV1

  @spec operator_workflow_signal_authority_module() :: module()
  def operator_workflow_signal_authority_module, do: OperatorWorkflowSignalAuthorityV1

  @spec persistence_posture_module() :: module()
  def persistence_posture_module, do: PersistencePosture

  @spec contract_version() :: String.t()
  def contract_version, do: AuthorityPacketV2.contract_version()

  @spec packet_name() :: String.t()
  def packet_name, do: AuthorityPacketV2.packet_name()

  @spec versioning_rule() :: atom()
  def versioning_rule, do: :explicit_successor_required_for_field_or_semantic_change

  @spec extensions_namespaces() :: [String.t()]
  def extensions_namespaces, do: @extensions_namespaces

  @spec manifest() :: map()
  def manifest, do: @manifest
end
