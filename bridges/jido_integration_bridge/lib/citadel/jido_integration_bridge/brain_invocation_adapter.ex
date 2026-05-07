defmodule Citadel.JidoIntegrationBridge.BrainInvocationAdapter do
  @moduledoc """
  Pure projection from Citadel's execution-intent handoff into the durable
  `Jido.Integration.V2.BrainInvocation` packet.

  The bridge carries the frozen lineage `session_id` required by the shared
  contracts, but it does not depend on HostIngress session ownership,
  continuity blobs, or any second durable submission queue.
  """

  alias Citadel.AuthorityContract.AuthorityDecision.V1, as: AuthorityDecisionV1
  alias Citadel.AuthorityContract.PersistencePosture
  alias Citadel.ExecutionGovernance.V1, as: ExecutionGovernanceV1
  alias Citadel.ExecutionIntentEnvelope.V2, as: ExecutionIntentEnvelopeV2
  alias Jido.Integration.V2.AuthorityAuditEnvelope
  alias Jido.Integration.V2.BrainInvocation
  alias Jido.Integration.V2.ExecutionGovernanceProjection
  alias Jido.Integration.V2.ExecutionGovernanceProjection.Compiler
  alias Jido.Integration.V2.ExecutionGovernanceProjection.Verifier
  alias Jido.Integration.V2.SubmissionIdentity

  @spec project!(ExecutionIntentEnvelopeV2.t()) :: BrainInvocation.t()
  def project!(%ExecutionIntentEnvelopeV2{} = envelope) do
    authority_payload = authority_payload(envelope.authority_packet)
    governance_payload = governance_payload(envelope.execution_governance)
    shadows = Compiler.compile!(governance_payload)

    :ok =
      Verifier.verify!(
        governance_payload,
        shadows.gateway_request,
        shadows.runtime_request,
        shadows.boundary_request
      )

    BrainInvocation.new!(%{
      submission_identity: submission_identity(envelope, governance_payload),
      request_id: envelope.request_id,
      session_id: envelope.session_id,
      tenant_id: envelope.tenant_id,
      trace_id: envelope.trace_id,
      actor_id: envelope.actor_id,
      target_id: envelope.target_id,
      target_kind: envelope.target_kind,
      runtime_class: infer_runtime_class(envelope),
      allowed_operations: envelope.allowed_operations,
      authority_payload: authority_payload,
      execution_governance_payload: governance_payload,
      gateway_request: shadows.gateway_request,
      runtime_request: shadows.runtime_request,
      boundary_request: shadows.boundary_request,
      execution_intent_family: envelope.execution_intent_family,
      execution_intent: dump_packet_struct!(envelope.execution_intent),
      extensions: invocation_extensions(envelope)
    })
  end

  defp authority_payload(%AuthorityDecisionV1{} = authority_packet) do
    authority_packet
    |> AuthorityDecisionV1.dump()
    |> AuthorityAuditEnvelope.new!()
  end

  defp governance_payload(%ExecutionGovernanceV1{} = execution_governance) do
    execution_governance
    |> ExecutionGovernanceV1.dump()
    |> ExecutionGovernanceProjection.new!()
  end

  defp submission_identity(%ExecutionIntentEnvelopeV2{} = envelope, governance_payload) do
    SubmissionIdentity.new!(%{
      submission_family: :invocation,
      tenant_id: envelope.tenant_id,
      session_id: envelope.session_id,
      request_id: envelope.request_id,
      invocation_request_id: envelope.invocation_request_id,
      causal_group_id: envelope.causal_group_id,
      target_id: envelope.target_id,
      target_kind: envelope.target_kind,
      selected_step_id: selected_step_id!(envelope),
      authority_decision_id: envelope.authority_packet.decision_id,
      execution_governance_id: governance_payload.execution_governance_id,
      execution_intent_family: envelope.execution_intent_family,
      extensions: %{}
    })
  end

  defp selected_step_id!(%ExecutionIntentEnvelopeV2{} = envelope) do
    case Map.get(envelope.extensions, "selected_step_id") do
      value when is_binary(value) ->
        if byte_size(String.trim(value)) > 0 do
          value
        else
          raise ArgumentError,
                "Citadel.JidoIntegrationBridge requires envelope.extensions[\"selected_step_id\"], got: #{inspect(value)}"
        end

      other ->
        raise ArgumentError,
              "Citadel.JidoIntegrationBridge requires envelope.extensions[\"selected_step_id\"], got: #{inspect(other)}"
    end
  end

  defp infer_runtime_class(%ExecutionIntentEnvelopeV2{} = envelope) do
    case envelope.topology_intent.session_mode do
      "attached" ->
        :session

      "detached" ->
        :session

      "stateless" ->
        :direct

      other ->
        raise ArgumentError,
              "unsupported topology session_mode for runtime_class: #{inspect(other)}"
    end
  end

  defp dump_packet_struct!(%module{} = packet) do
    if function_exported?(module, :dump, 1) do
      module.dump(packet)
    else
      raise ArgumentError,
            "Citadel.JidoIntegrationBridge cannot dump packet #{inspect(module)} without dump/1"
    end
  end

  defp invocation_extensions(%ExecutionIntentEnvelopeV2{} = envelope) do
    %{
      "citadel" => %{
        "entry_id" => envelope.entry_id,
        "intent_envelope_id" => envelope.intent_envelope_id,
        "causal_group_id" => envelope.causal_group_id,
        "invocation_schema_version" => envelope.invocation_schema_version,
        "selected_step_id" => selected_step_id!(envelope),
        "downstream_scope" => Map.get(envelope.extensions, "downstream_scope"),
        "authority_persistence_posture" =>
          envelope.authority_packet
          |> AuthorityDecisionV1.persistence_posture()
          |> PersistencePosture.string_keys(),
        "execution_governance_persistence_posture" =>
          execution_governance_persistence_posture(envelope.execution_governance)
      }
    }
    |> maybe_put_submission_dedupe_key(Map.get(envelope.extensions, "submission_dedupe_key"))
  end

  defp execution_governance_persistence_posture(%ExecutionGovernanceV1{} = governance) do
    governance.extensions
    |> get_in(["citadel", "persistence_posture"])
    |> case do
      %{} = posture ->
        posture

      _missing ->
        PersistencePosture.memory(:authority_decision) |> PersistencePosture.string_keys()
    end
  end

  defp maybe_put_submission_dedupe_key(extensions, value) when is_binary(value) and value != "" do
    Map.put(extensions, "submission_dedupe_key", value)
  end

  defp maybe_put_submission_dedupe_key(extensions, _value), do: extensions
end
