defmodule Citadel.ExecutionGovernanceCompiler do
  @moduledoc """
  Pure compiler from existing Citadel decision values into `ExecutionGovernance.v1`.
  """

  alias Citadel.AuthorityContract.AuthorityDecision.V1, as: AuthorityDecisionV1
  alias Citadel.AuthorityContract.PersistencePosture
  alias Citadel.BoundaryIntent
  alias Citadel.ContractCore.Value
  alias Citadel.ExecutionGovernance.V1, as: ExecutionGovernanceV1
  alias Citadel.TopologyIntent

  @attrs_schema [
    :execution_governance_id,
    :sandbox_level,
    :sandbox_egress,
    :sandbox_approvals,
    :acceptable_attestation,
    :allowed_tools,
    :file_scope_ref,
    :file_scope_hint,
    :logical_workspace_ref,
    :workspace_mutability,
    :execution_family,
    :placement_intent,
    :target_kind,
    :node_affinity,
    :allowed_operations,
    :effect_classes,
    :cpu_class,
    :memory_class,
    :wall_clock_budget_ms,
    :persistence_posture,
    :extensions
  ]

  @spec compile!(
          AuthorityDecisionV1.t(),
          BoundaryIntent.t(),
          TopologyIntent.t(),
          map() | keyword()
        ) :: ExecutionGovernanceV1.t()
  def compile!(
        %AuthorityDecisionV1{} = authority_packet,
        %BoundaryIntent{} = boundary_intent,
        %TopologyIntent{} = topology_intent,
        attrs
      ) do
    attrs = Value.normalize_attrs!(attrs, "Citadel.ExecutionGovernanceCompiler", @attrs_schema)

    ExecutionGovernanceV1.new!(%{
      contract_version: ExecutionGovernanceV1.contract_version(),
      execution_governance_id:
        Value.required(
          attrs,
          :execution_governance_id,
          "Citadel.ExecutionGovernanceCompiler",
          fn value ->
            Value.string!(value, "Citadel.ExecutionGovernanceCompiler.execution_governance_id")
          end
        ),
      authority_ref: %{
        "decision_id" => authority_packet.decision_id,
        "policy_version" => authority_packet.policy_version,
        "decision_hash" => authority_packet.decision_hash
      },
      sandbox: %{
        "level" =>
          Value.required(attrs, :sandbox_level, "Citadel.ExecutionGovernanceCompiler", fn value ->
            Value.string!(value, "Citadel.ExecutionGovernanceCompiler.sandbox_level")
          end),
        "egress" =>
          Value.required(
            attrs,
            :sandbox_egress,
            "Citadel.ExecutionGovernanceCompiler",
            fn value ->
              Value.string!(value, "Citadel.ExecutionGovernanceCompiler.sandbox_egress")
            end
          ),
        "approvals" =>
          Value.required(
            attrs,
            :sandbox_approvals,
            "Citadel.ExecutionGovernanceCompiler",
            fn value ->
              Value.string!(value, "Citadel.ExecutionGovernanceCompiler.sandbox_approvals")
            end
          ),
        "acceptable_attestation" =>
          Value.required(
            attrs,
            :acceptable_attestation,
            "Citadel.ExecutionGovernanceCompiler",
            fn value ->
              Value.unique_strings!(
                value,
                "Citadel.ExecutionGovernanceCompiler.acceptable_attestation",
                allow_empty?: false
              )
            end
          ),
        "allowed_tools" =>
          Value.optional(
            attrs,
            :allowed_tools,
            "Citadel.ExecutionGovernanceCompiler",
            fn value ->
              Value.unique_strings!(value, "Citadel.ExecutionGovernanceCompiler.allowed_tools")
            end,
            []
          ),
        "file_scope_ref" =>
          Value.required(
            attrs,
            :file_scope_ref,
            "Citadel.ExecutionGovernanceCompiler",
            fn value ->
              Value.string!(value, "Citadel.ExecutionGovernanceCompiler.file_scope_ref")
            end
          ),
        "file_scope_hint" =>
          Value.optional(
            attrs,
            :file_scope_hint,
            "Citadel.ExecutionGovernanceCompiler",
            fn value ->
              Value.string!(value, "Citadel.ExecutionGovernanceCompiler.file_scope_hint")
            end,
            nil
          )
      },
      boundary: %{
        "boundary_class" => boundary_intent.boundary_class,
        "trust_profile" => boundary_intent.trust_profile,
        "requested_attach_mode" => boundary_intent.requested_attach_mode,
        "requested_ttl_ms" => boundary_intent.requested_ttl_ms
      },
      topology: %{
        "topology_intent_id" => topology_intent.topology_intent_id,
        "session_mode" => topology_intent.session_mode,
        "coordination_mode" => topology_intent.coordination_mode,
        "topology_epoch" => topology_intent.topology_epoch,
        "routing_hints" => topology_intent.routing_hints
      },
      workspace: %{
        "workspace_profile" => authority_packet.workspace_profile,
        "logical_workspace_ref" =>
          Value.required(
            attrs,
            :logical_workspace_ref,
            "Citadel.ExecutionGovernanceCompiler",
            fn value ->
              Value.string!(value, "Citadel.ExecutionGovernanceCompiler.logical_workspace_ref")
            end
          ),
        "mutability" =>
          Value.required(
            attrs,
            :workspace_mutability,
            "Citadel.ExecutionGovernanceCompiler",
            fn value ->
              Value.string!(value, "Citadel.ExecutionGovernanceCompiler.workspace_mutability")
            end
          )
      },
      resources: %{
        "resource_profile" => authority_packet.resource_profile,
        "cpu_class" =>
          Value.optional(attrs, :cpu_class, "Citadel.ExecutionGovernanceCompiler", fn value ->
            Value.string!(value, "Citadel.ExecutionGovernanceCompiler.cpu_class")
          end),
        "memory_class" =>
          Value.optional(attrs, :memory_class, "Citadel.ExecutionGovernanceCompiler", fn value ->
            Value.string!(value, "Citadel.ExecutionGovernanceCompiler.memory_class")
          end),
        "wall_clock_budget_ms" =>
          Value.optional(
            attrs,
            :wall_clock_budget_ms,
            "Citadel.ExecutionGovernanceCompiler",
            fn value ->
              Value.non_neg_integer!(
                value,
                "Citadel.ExecutionGovernanceCompiler.wall_clock_budget_ms"
              )
            end
          )
      },
      placement: %{
        "execution_family" =>
          Value.required(
            attrs,
            :execution_family,
            "Citadel.ExecutionGovernanceCompiler",
            fn value ->
              Value.string!(value, "Citadel.ExecutionGovernanceCompiler.execution_family")
            end
          ),
        "placement_intent" =>
          Value.required(
            attrs,
            :placement_intent,
            "Citadel.ExecutionGovernanceCompiler",
            fn value ->
              Value.string!(value, "Citadel.ExecutionGovernanceCompiler.placement_intent")
            end
          ),
        "target_kind" =>
          Value.required(attrs, :target_kind, "Citadel.ExecutionGovernanceCompiler", fn value ->
            Value.string!(value, "Citadel.ExecutionGovernanceCompiler.target_kind")
          end),
        "node_affinity" =>
          Value.optional(
            attrs,
            :node_affinity,
            "Citadel.ExecutionGovernanceCompiler",
            fn value ->
              Value.string!(value, "Citadel.ExecutionGovernanceCompiler.node_affinity")
            end
          )
      },
      operations: %{
        "allowed_operations" =>
          Value.required(
            attrs,
            :allowed_operations,
            "Citadel.ExecutionGovernanceCompiler",
            fn value ->
              Value.unique_strings!(
                value,
                "Citadel.ExecutionGovernanceCompiler.allowed_operations",
                allow_empty?: false
              )
            end
          ),
        "effect_classes" =>
          Value.optional(
            attrs,
            :effect_classes,
            "Citadel.ExecutionGovernanceCompiler",
            fn value ->
              Value.unique_strings!(value, "Citadel.ExecutionGovernanceCompiler.effect_classes")
            end,
            []
          )
      },
      extensions:
        attrs
        |> Value.optional(
          :extensions,
          "Citadel.ExecutionGovernanceCompiler",
          fn value ->
            Value.json_object!(value, "Citadel.ExecutionGovernanceCompiler.extensions")
          end,
          %{"citadel" => %{}}
        )
        |> include_action_binding(authority_packet)
        |> include_persistence_posture(authority_packet, attrs)
    })
  end

  defp include_action_binding(extensions, %AuthorityDecisionV1{} = authority_packet) do
    case authority_for_action_ref(authority_packet) do
      nil ->
        extensions

      for_action_ref ->
        Map.update(extensions, "citadel", %{"for_action_ref" => for_action_ref}, fn
          %{} = citadel -> Map.put_new(citadel, "for_action_ref", for_action_ref)
          _other -> %{"for_action_ref" => for_action_ref}
        end)
    end
  end

  defp authority_for_action_ref(%AuthorityDecisionV1{extensions: extensions}) do
    extensions
    |> case do
      %{} = root ->
        case Map.get(root, "citadel") do
          %{} = citadel -> Map.get(citadel, "for_action_ref")
          _other -> nil
        end

      _other ->
        nil
    end
    |> case do
      value when is_binary(value) and value != "" -> value
      _other -> nil
    end
  end

  defp include_persistence_posture(extensions, %AuthorityDecisionV1{} = authority_packet, attrs) do
    posture =
      case Map.get(attrs, :persistence_posture) || Map.get(attrs, "persistence_posture") do
        %{} = supplied ->
          PersistencePosture.resolve(:authority_decision, persistence_posture: supplied)

        _missing ->
          AuthorityDecisionV1.persistence_posture(authority_packet)
      end
      |> PersistencePosture.string_keys()

    Map.update(extensions, "citadel", %{"persistence_posture" => posture}, fn
      %{} = citadel -> Map.put(citadel, "persistence_posture", posture)
      _other -> %{"persistence_posture" => posture}
    end)
  end
end
