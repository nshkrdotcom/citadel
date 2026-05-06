defmodule Citadel.Governance.SubstrateIngress do
  @moduledoc """
  Pure substrate-origin governance compiler.

  This module deliberately lives in `citadel_governance`, not
  `citadel_host_ingress_bridge`. It compiles Mezzanine-origin execution packets
  into Citadel authority and lower invocation work without touching host session
  continuity, `SessionDirectory`, or `SessionServer`.
  """

  alias Citadel.ActionOutboxEntry
  alias Citadel.AuthorityContract.AuthorityDecision.V1, as: AuthorityDecisionV1
  alias Citadel.BackoffPolicy
  alias Citadel.BoundaryIntent
  alias Citadel.DecisionHash
  alias Citadel.DecisionRejection
  alias Citadel.DecisionRejectionClassifier
  alias Citadel.ExecutionGovernanceCompiler
  alias Citadel.IntentEnvelope
  alias Citadel.IntentEnvelope.ScopeSelector
  alias Citadel.IntentEnvelope.TargetHint
  alias Citadel.IntentMappingConstraints
  alias Citadel.InvocationRequest.V2, as: InvocationRequestV2
  alias Citadel.LocalAction
  alias Citadel.PlanHints
  alias Citadel.PlanHints.CandidateStep
  alias Citadel.PolicyPacks
  alias Citadel.PolicyPacks.ExecutionPolicy
  alias Citadel.PolicyPacks.Selection
  alias Citadel.StalenessRequirements
  alias Citadel.TopologyIntent

  @default_requested_ttl_ms 60_000
  @default_execution_family "process"
  @default_placement_intent "remote_workspace"
  @default_wall_clock_budget_ms 60_000
  @allowed_approval_modes ["manual", "auto", "none"]
  @allowed_egress_policies ["blocked", "restricted", "open"]
  @allowed_workspace_mutabilities ["read_only", "read_write", "ephemeral"]
  @allowed_execution_families ["process", "http", "json_rpc", "service"]
  @allowed_placement_intents [
    "host_local",
    "remote_scope",
    "remote_workspace",
    "ephemeral_session"
  ]
  @allowed_sandbox_levels ["strict", "standard", "none"]
  @sandbox_rank %{"strict" => 0, "standard" => 1, "none" => 2}
  @egress_rank %{"blocked" => 0, "restricted" => 1, "open" => 2}
  @approval_rank %{"manual" => 0, "auto" => 1, "none" => 2}
  @workspace_mutability_rank %{"read_only" => 0, "read_write" => 1, "ephemeral" => 2}
  @action_kind "citadel.substrate_invocation_request.v2"

  @type packet :: map()
  @type accepted :: %{
          authority_packet: AuthorityDecisionV1.t(),
          decision_hash: String.t(),
          rejection_classification: nil,
          lower_intent: %{
            invocation_request: InvocationRequestV2.t(),
            outbox_entry: ActionOutboxEntry.t(),
            entry_id: String.t()
          },
          audit_attrs: map()
        }
  @type rejected :: %{
          class: :auth_error | :policy_error | :validation_error | :semantic_failure,
          terminal?: boolean(),
          decision_hash: String.t() | nil,
          audit_attrs: map(),
          operator_message: String.t(),
          rejection_classification: map() | nil
        }

  @spec action_kind() :: String.t()
  def action_kind, do: @action_kind

  @spec compile(packet(), [Selection.t() | map()], keyword()) ::
          {:ok, accepted()} | {:error, rejected()}
  def compile(packet, policy_packs, opts \\ []) when is_map(packet) and is_list(policy_packs) do
    packet = normalize_packet!(packet)
    envelope = IntentEnvelope.new!(packet.intent_envelope)
    selection = select_policy!(policy_packs, envelope, packet)

    case IntentMappingConstraints.planning_status(envelope) do
      :plannable ->
        compile_plannable(packet, envelope, selection, opts)

      {:unplannable, reason_code} ->
        rejection = classify_rejection!(packet, selection, reason_code)
        {:error, rejection_result(packet, rejection)}
    end
  rescue
    error in ArgumentError ->
      {:error,
       %{
         class: :validation_error,
         terminal?: true,
         decision_hash: nil,
         audit_attrs: validation_audit_attrs(packet, error),
         operator_message: Exception.message(error),
         rejection_classification: nil
       }}
  end

  defp compile_plannable(packet, envelope, selection, opts) do
    with {:ok, selector} <- first_scope_selector(envelope),
         {:ok, target_hint} <- first_target_hint(envelope),
         {:ok, candidate_step} <- first_candidate_step(envelope),
         {:ok, step_extensions} <- citadel_step_extensions(candidate_step),
         {:ok, execution_intent_family} <- execution_intent_family(step_extensions),
         {:ok, execution_intent} <- execution_intent(step_extensions),
         {:ok, target_id} <- target_id(target_hint, selector, packet),
         {:ok, authority_context} <- authority_context(packet, selection, target_id, opts),
         {:ok, boundary_intent} <- boundary_intent(envelope, selection, opts),
         {:ok, topology_intent} <-
           topology_intent(
             envelope,
             packet,
             target_hint,
             execution_intent_family,
             execution_intent,
             step_extensions
           ),
         {:ok, authority_packet} <-
           authority_packet(packet, selection, boundary_intent, authority_context),
         {:ok, execution_governance} <-
           execution_governance(
             packet,
             selector,
             target_hint,
             candidate_step,
             selection,
             authority_packet,
             boundary_intent,
             topology_intent,
             execution_intent_family,
             step_extensions
           ),
         {:ok, invocation_request} <-
           invocation_request(
             packet,
             target_hint,
             target_id,
             candidate_step,
             authority_packet,
             boundary_intent,
             topology_intent,
             execution_governance,
             execution_intent_family,
             execution_intent,
             step_extensions
           ) do
      entry_id = "submit/#{packet.execution_id}"
      outbox_entry = outbox_entry(entry_id, packet, selection, invocation_request, opts)

      {:ok,
       %{
         authority_packet: authority_packet,
         decision_hash: authority_packet.decision_hash,
         rejection_classification: nil,
         lower_intent: %{
           invocation_request: invocation_request,
           outbox_entry: outbox_entry,
           entry_id: entry_id
         },
         audit_attrs: accepted_audit_attrs(packet, authority_packet)
       }}
    else
      {:error, {:planning, reason_code}} ->
        rejection = classify_rejection!(packet, selection, reason_code)
        {:error, rejection_result(packet, rejection)}

      {:error, {:authorization, reason_code, metadata}} ->
        {:error, authorization_rejection_result(packet, reason_code, metadata)}
    end
  end

  defp normalize_packet!(packet) do
    %{
      tenant_id: required_string!(packet, :tenant_id),
      installation_id: required_string!(packet, :installation_id),
      installation_revision: required_revision!(packet),
      actor_ref: required_string!(packet, :actor_ref),
      subject_id: required_string!(packet, :subject_id),
      execution_id: required_string!(packet, :execution_id),
      decision_id: optional_string(packet, :decision_id),
      request_trace_id: required_string!(packet, :request_trace_id),
      substrate_trace_id: required_string!(packet, :substrate_trace_id),
      idempotency_key: required_string!(packet, :idempotency_key),
      capability_refs:
        string_list!(Map.get(packet, :capability_refs) || Map.get(packet, "capability_refs")),
      policy_refs: string_list!(Map.get(packet, :policy_refs) || Map.get(packet, "policy_refs")),
      run_intent: json_object!(packet, :run_intent),
      placement_constraints: json_object!(packet, :placement_constraints),
      risk_hints: string_list!(Map.get(packet, :risk_hints) || Map.get(packet, "risk_hints")),
      metadata: json_object!(packet, :metadata),
      intent_envelope: required_map!(packet, :intent_envelope),
      environment: optional_string(packet, :environment) || "dev",
      policy_epoch: optional_non_neg_integer(packet, :policy_epoch)
    }
  end

  defp select_policy!(policy_packs, envelope, packet) do
    selector = List.first(envelope.scope_selectors)

    if is_nil(selector) do
      raise ArgumentError, "substrate ingress compilation requires at least one scope selector"
    end

    PolicyPacks.select_profile!(policy_packs, %{
      tenant_id: packet.tenant_id,
      scope_kind: selector.scope_kind,
      environment: selector.environment || packet.environment,
      policy_epoch: packet.policy_epoch || packet.installation_revision
    })
  end

  defp first_scope_selector(%IntentEnvelope{
         scope_selectors: [%ScopeSelector{} = selector | _rest]
       }),
       do: {:ok, selector}

  defp first_scope_selector(_envelope), do: {:error, {:planning, "missing_scope_selector"}}

  defp first_target_hint(%IntentEnvelope{target_hints: [%TargetHint{} = hint | _rest]}),
    do: {:ok, hint}

  defp first_target_hint(_envelope), do: {:error, {:planning, "missing_target_hint"}}

  defp first_candidate_step(%IntentEnvelope{
         plan_hints: %PlanHints{candidate_steps: [%CandidateStep{} = step | _rest]}
       }),
       do: {:ok, step}

  defp first_candidate_step(_envelope), do: {:error, {:planning, "missing_candidate_step"}}

  defp citadel_step_extensions(%CandidateStep{extensions: %{"citadel" => extensions}})
       when is_map(extensions),
       do: {:ok, extensions}

  defp citadel_step_extensions(%CandidateStep{}), do: {:ok, %{}}

  defp execution_intent_family(extensions) do
    value = Map.get(extensions, "execution_intent_family", @default_execution_family)

    if value in @allowed_execution_families do
      {:ok, value}
    else
      {:error, {:planning, "unsupported_execution_intent_family"}}
    end
  end

  defp execution_intent(extensions) do
    case Map.get(extensions, "execution_intent") do
      value when is_map(value) ->
        {:ok, value}

      nil ->
        {:error, {:planning, "missing_execution_intent"}}

      _other ->
        {:error, {:planning, "invalid_execution_intent"}}
    end
  end

  defp target_id(%TargetHint{preferred_target_id: target_id}, _selector, _packet)
       when is_binary(target_id) and target_id != "",
       do: {:ok, target_id}

  defp target_id(%TargetHint{}, %ScopeSelector{scope_id: scope_id}, _packet)
       when is_binary(scope_id) and scope_id != "",
       do: {:ok, scope_id}

  defp target_id(_target_hint, _selector, packet) do
    case Map.get(packet.placement_constraints, "placement_ref") do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, {:planning, "missing_target_id"}}
    end
  end

  defp boundary_intent(envelope, selection, opts) do
    mapping = IntentMappingConstraints.boundary_mapping(envelope)
    ttl_ms = Keyword.get(opts, :requested_ttl_ms, @default_requested_ttl_ms)

    {:ok,
     BoundaryIntent.new!(%{
       boundary_class: mapping.preferred_boundary_class || selection.profiles.boundary_class,
       trust_profile: selection.profiles.trust_profile,
       workspace_profile: selection.profiles.workspace_profile,
       resource_profile: selection.profiles.resource_profile,
       requested_attach_mode: mapping.requested_attach_mode,
       requested_ttl_ms: ttl_ms,
       extensions: %{}
     })}
  end

  defp topology_intent(
         envelope,
         packet,
         %TargetHint{} = target_hint,
         execution_intent_family,
         execution_intent,
         step_extensions
       ) do
    mapping = IntentMappingConstraints.topology_mapping(envelope)

    preferred_topology =
      case envelope.plan_hints do
        %PlanHints{preferred_topology: value} -> value
        _other -> nil
      end

    routing_hints =
      mapping.routing_hints
      |> Map.merge(preferred_topology_routing_hints(preferred_topology))
      |> Map.put("execution_intent_family", execution_intent_family)
      |> Map.put("execution_intent", execution_intent)
      |> Map.put("installation_id", packet.installation_id)
      |> Map.put("installation_revision", packet.installation_revision)
      |> Map.put(
        "downstream_scope",
        downstream_scope(step_extensions, execution_intent_family, target_hint.target_kind)
      )

    {:ok,
     TopologyIntent.new!(%{
       topology_intent_id: "topology/#{packet.execution_id}",
       session_mode:
         preferred_topology_value(preferred_topology, :session_mode) ||
           Atom.to_string(mapping.session_mode),
       coordination_mode:
         preferred_topology_value(preferred_topology, :coordination_mode) ||
           Atom.to_string(mapping.coordination_mode),
       routing_hints: routing_hints,
       topology_epoch: 0,
       extensions: %{}
     })}
  end

  defp authority_context(packet, %Selection{} = selection, target_id, opts) do
    case Keyword.get(opts, :access_graph_reader) do
      nil ->
        {:ok, nil}

      reader ->
        query = authority_query(packet, selection, target_id)

        case read_authority_graph(reader, query) do
          {:ok, view} -> authorize_graph_view(view)
          {:error, {:stale_epoch, metadata}} -> stale_epoch_error(metadata)
          {:error, reason} -> {:error, {:authorization, to_string(reason), %{}}}
        end
    end
  end

  defp authority_query(packet, %Selection{} = selection, target_id) do
    requested_epoch = packet.policy_epoch || selection.policy_epoch

    %{
      tenant_ref: packet.tenant_id,
      user_ref: packet.subject_id,
      agent_ref: packet.actor_ref,
      resource_ref: target_id,
      requested_epoch: requested_epoch,
      policy_refs: packet.policy_refs,
      effective_access_tuple: %{
        access_agents: [packet.actor_ref],
        access_resources: [target_id],
        access_scopes: [target_id],
        policy_refs: packet.policy_refs
      },
      allow_stale?: false
    }
  end

  defp read_authority_graph(reader, query) when is_function(reader, 1), do: reader.(query)

  defp read_authority_graph(reader, query) when is_atom(reader) do
    reader.authority_compile_view(
      query.tenant_ref,
      query.user_ref,
      query.agent_ref,
      query.requested_epoch,
      query.effective_access_tuple
    )
  end

  defp authorize_graph_view(view) do
    if graph_admissible?(view) do
      {:ok, access_graph_extension(view)}
    else
      {:error, {:authorization, "access_graph_denied", %{}}}
    end
  end

  defp graph_admissible?(view) when is_map(view) do
    Map.get(view, :graph_admissible?) == true or Map.get(view, "graph_admissible?") == true
  end

  defp stale_epoch_error(metadata) when is_map(metadata) do
    {:error, {:authorization, "stale_authority_epoch", metadata}}
  end

  defp stale_epoch_error(metadata), do: stale_epoch_error(%{reason: inspect(metadata)})

  defp access_graph_extension(view) do
    %{
      "snapshot_epoch" => view_value(view, :snapshot_epoch),
      "source_node_ref" => view_value(view, :source_node_ref),
      "commit_lsn" => view_value(view, :commit_lsn),
      "commit_hlc" => view_value(view, :commit_hlc),
      "policy_refs" => view |> view_value(:policy_refs) |> sorted_strings()
    }
  end

  defp view_value(view, key), do: Map.get(view, key) || Map.get(view, Atom.to_string(key))

  defp sorted_strings(%MapSet{} = values), do: values |> MapSet.to_list() |> Enum.sort()

  defp sorted_strings(values) when is_list(values) do
    values
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp sorted_strings(_values), do: []

  defp authority_packet(
         packet,
         %Selection{} = selection,
         %BoundaryIntent{} = boundary_intent,
         authority_context
       ) do
    citadel_extensions =
      %{
        "policy_pack_id" => selection.pack_id,
        "ingress_kind" => "substrate_origin",
        "installation_id" => packet.installation_id,
        "installation_revision" => packet.installation_revision,
        "request_trace_id" => packet.request_trace_id,
        "substrate_trace_id" => packet.substrate_trace_id
      }
      |> maybe_put_prompt_version_policy(selection.prompt_version_policy)
      |> maybe_put_guardrail_chain_policy(selection.guardrail_chain_policy)
      |> maybe_put_access_graph(authority_context)

    {:ok,
     DecisionHash.put_authority_hash!(%{
       contract_version: AuthorityDecisionV1.contract_version(),
       decision_id: packet.decision_id || "decision/#{packet.execution_id}",
       tenant_id: packet.tenant_id,
       request_id: packet.execution_id,
       policy_version: selection.policy_version,
       boundary_class: boundary_intent.boundary_class,
       trust_profile: selection.profiles.trust_profile,
       approval_profile: selection.profiles.approval_profile,
       egress_profile: selection.profiles.egress_profile,
       workspace_profile: selection.profiles.workspace_profile,
       resource_profile: selection.profiles.resource_profile,
       extensions: %{"citadel" => citadel_extensions}
     })}
  end

  defp maybe_put_access_graph(extensions, nil), do: extensions

  defp maybe_put_access_graph(extensions, access_graph) when is_map(access_graph) do
    Map.put(extensions, "access_graph", access_graph)
  end

  defp maybe_put_prompt_version_policy(extensions, nil), do: extensions

  defp maybe_put_prompt_version_policy(extensions, policy)
       when is_map(policy) and not is_struct(policy) do
    Map.put(extensions, "prompt_version_policy", policy)
  end

  defp maybe_put_prompt_version_policy(extensions, policy) do
    Map.put(extensions, "prompt_version_policy", %{
      "allowed_prompt_refs" => policy.allowed_prompt_refs,
      "allowed_revision_range" => policy.allowed_revision_range,
      "ab_variant_refs" => policy.ab_variant_refs,
      "rollback_requires_authority" => policy.rollback_requires_authority?,
      "eval_evidence_required" => policy.eval_evidence_required?,
      "guard_evidence_required" => policy.guard_evidence_required?
    })
  end

  defp maybe_put_guardrail_chain_policy(extensions, nil), do: extensions

  defp maybe_put_guardrail_chain_policy(extensions, policy)
       when is_map(policy) and not is_struct(policy) do
    Map.put(extensions, "guardrail_chain_policy", policy)
  end

  defp maybe_put_guardrail_chain_policy(extensions, policy) do
    Map.put(extensions, "guardrail_chain_policy", %{
      "guard_chain_ref" => policy.guard_chain_ref,
      "detector_refs" => policy.detector_refs,
      "redaction_posture_floor" => policy.redaction_posture_floor,
      "operator_override_authority_refs" => policy.operator_override_authority_refs,
      "fail_closed" => policy.fail_closed?
    })
  end

  defp execution_governance(
         packet,
         %ScopeSelector{} = selector,
         %TargetHint{} = target_hint,
         %CandidateStep{} = candidate_step,
         selection,
         authority_packet,
         boundary_intent,
         topology_intent,
         execution_intent_family,
         step_extensions
       ) do
    logical_workspace_ref = logical_workspace_ref(selector)

    with {:ok, governance_attrs} <-
           execution_governance_attrs(
             selection,
             candidate_step,
             step_extensions,
             execution_intent_family
           ) do
      {:ok,
       ExecutionGovernanceCompiler.compile!(
         authority_packet,
         boundary_intent,
         topology_intent,
         [
           execution_governance_id: "execgov/#{packet.execution_id}",
           file_scope_ref: logical_workspace_ref,
           file_scope_hint: selector.workspace_root,
           logical_workspace_ref: logical_workspace_ref,
           target_kind: target_hint.target_kind,
           node_affinity: normalize_optional_string(Map.get(step_extensions, "node_affinity")),
           cpu_class: normalize_optional_string(Map.get(step_extensions, "cpu_class")),
           memory_class: normalize_optional_string(Map.get(step_extensions, "memory_class"))
         ] ++ governance_attrs
       )}
    end
  end

  defp execution_governance_attrs(
         %Selection{} = selection,
         %CandidateStep{} = candidate_step,
         step_extensions,
         execution_intent_family
       ) do
    requested = %{
      sandbox_level: sandbox_level(step_extensions, candidate_step, selection),
      sandbox_egress: sandbox_egress(step_extensions, selection.profiles.egress_profile),
      sandbox_approvals: sandbox_approvals(step_extensions, selection.profiles.approval_profile),
      acceptable_attestation: acceptable_attestation(step_extensions, selection.execution_policy),
      allowed_tools: normalize_string_list(Map.get(step_extensions, "allowed_tools", [])),
      workspace_mutability: workspace_mutability(step_extensions, candidate_step),
      execution_family: execution_family(step_extensions, execution_intent_family),
      placement_intent: placement_intent(step_extensions),
      allowed_operations: candidate_step.allowed_operations,
      effect_classes: effect_classes(step_extensions, candidate_step),
      wall_clock_budget_ms:
        normalize_optional_non_neg_integer(
          Map.get(step_extensions, "wall_clock_budget_ms", @default_wall_clock_budget_ms)
        )
    }

    with :ok <- enforce_execution_policy(selection.execution_policy, requested) do
      {:ok,
       [
         sandbox_level: requested.sandbox_level,
         sandbox_egress: requested.sandbox_egress,
         sandbox_approvals: requested.sandbox_approvals,
         acceptable_attestation: requested.acceptable_attestation,
         allowed_tools: requested.allowed_tools,
         workspace_mutability: requested.workspace_mutability,
         execution_family: requested.execution_family,
         placement_intent: requested.placement_intent,
         allowed_operations: requested.allowed_operations,
         effect_classes: requested.effect_classes,
         wall_clock_budget_ms: requested.wall_clock_budget_ms
       ]}
    end
  end

  defp enforce_execution_policy(nil, _requested), do: :ok

  defp enforce_execution_policy(%ExecutionPolicy{} = policy, requested) do
    cond do
      weaker_rank?(requested.sandbox_level, policy.minimum_sandbox_level, @sandbox_rank) ->
        {:error, {:planning, "sandbox_downgrade"}}

      weaker_rank?(requested.sandbox_egress, policy.maximum_egress, @egress_rank) ->
        {:error, {:planning, "egress_downgrade"}}

      weaker_rank?(requested.sandbox_approvals, policy.approval_mode, @approval_rank) ->
        {:error, {:planning, "approval_downgrade"}}

      not subset?(requested.allowed_tools, policy.allowed_tools) ->
        {:error, {:planning, "tool_not_allowed"}}

      not subset?(requested.allowed_operations, policy.allowed_operations) ->
        {:error, {:planning, "operation_not_allowed"}}

      not subset?(requested.effect_classes, policy.effect_classes) ->
        {:error, {:planning, "effect_class_not_allowed"}}

      requested.placement_intent not in policy.placement_intents ->
        {:error, {:planning, "unsupported_placement_intent"}}

      requested.execution_family not in policy.execution_families ->
        {:error, {:planning, "unsupported_execution_intent_family"}}

      weaker_rank?(
        requested.workspace_mutability,
        policy.workspace_mutability,
        @workspace_mutability_rank
      ) ->
        {:error, {:planning, "workspace_mutability_downgrade"}}

      over_budget?(requested.wall_clock_budget_ms, policy.wall_clock_budget_ms) ->
        {:error, {:planning, "wall_clock_budget_exceeded"}}

      true ->
        :ok
    end
  end

  defp weaker_rank?(requested, allowed, ranks) when is_map(ranks) do
    Map.fetch!(ranks, requested) > Map.fetch!(ranks, allowed)
  end

  defp subset?(_requested, []), do: true

  defp subset?(requested, allowed) do
    Enum.all?(requested, &(&1 in allowed))
  end

  defp over_budget?(_requested, nil), do: false
  defp over_budget?(nil, _allowed), do: false
  defp over_budget?(requested, allowed), do: requested > allowed

  defp invocation_request(
         packet,
         %TargetHint{} = target_hint,
         target_id,
         %CandidateStep{} = candidate_step,
         authority_packet,
         boundary_intent,
         topology_intent,
         execution_governance,
         execution_intent_family,
         execution_intent,
         step_extensions
       ) do
    citadel_extensions =
      %{
        "execution_intent_family" => execution_intent_family,
        "execution_intent" => execution_intent,
        "ingress_provenance" => %{
          "ingress_kind" => "substrate_origin",
          "request_trace_id" => packet.request_trace_id,
          "substrate_trace_id" => packet.substrate_trace_id,
          "idempotency_key" => packet.idempotency_key,
          "metadata_keys" => metadata_keys(packet.metadata),
          "installation_id" => packet.installation_id,
          "installation_revision" => packet.installation_revision
        }
      }
      |> maybe_put_prompt_version_policy(
        authority_packet.extensions["citadel"]["prompt_version_policy"]
      )
      |> maybe_put_guardrail_chain_policy(
        authority_packet.extensions["citadel"]["guardrail_chain_policy"]
      )
      |> maybe_put_execution_envelope(step_extensions)

    {:ok,
     InvocationRequestV2.new!(%{
       schema_version: InvocationRequestV2.schema_version(),
       invocation_request_id: "invoke/#{packet.execution_id}",
       request_id: packet.execution_id,
       session_id: "substrate/#{packet.execution_id}",
       tenant_id: packet.tenant_id,
       trace_id: packet.substrate_trace_id,
       actor_id: packet.actor_ref,
       target_id: target_id,
       target_kind: target_hint.target_kind,
       selected_step_id: selected_step_id(packet, candidate_step),
       allowed_operations: candidate_step.allowed_operations,
       authority_packet: authority_packet,
       boundary_intent: boundary_intent,
       topology_intent: topology_intent,
       execution_governance: execution_governance,
       extensions: %{"citadel" => citadel_extensions}
     })}
  end

  defp outbox_entry(entry_id, packet, %Selection{} = selection, invocation_request, opts) do
    now = Keyword.get(opts, :inserted_at, DateTime.utc_now())

    ActionOutboxEntry.new!(%{
      schema_version: ActionOutboxEntry.schema_version(),
      entry_id: entry_id,
      causal_group_id: packet.execution_id,
      action:
        LocalAction.new!(%{
          action_kind: @action_kind,
          payload: %{
            "contract" => "citadel.invocation_request.v2",
            "invocation_request" => InvocationRequestV2.dump(invocation_request)
          },
          extensions: %{}
        }),
      inserted_at: now,
      replay_status: :pending,
      durable_receipt_ref: nil,
      attempt_count: 0,
      max_attempts: 3,
      backoff_policy:
        BackoffPolicy.new!(%{
          strategy: :fixed,
          base_delay_ms: 25,
          max_delay_ms: 250,
          linear_step_ms: nil,
          multiplier: nil,
          jitter_mode: :entry_stable,
          jitter_window_ms: 10,
          extensions: %{}
        }),
      next_attempt_at: nil,
      last_error_code: nil,
      dead_letter_reason: nil,
      ordering_mode: :strict,
      staleness_mode: :requires_check,
      staleness_requirements:
        StalenessRequirements.new!(%{
          snapshot_seq: 0,
          policy_epoch: selection.policy_epoch,
          topology_epoch: nil,
          scope_catalog_epoch: nil,
          service_admission_epoch: nil,
          project_binding_epoch: nil,
          boundary_epoch: nil,
          required_binding_id: nil,
          required_boundary_ref: nil,
          extensions: %{}
        }),
      extensions: %{
        "substrate_ingress" => %{
          "execution_id" => packet.execution_id,
          "trace_id" => packet.substrate_trace_id,
          "installation_id" => packet.installation_id,
          "installation_revision" => packet.installation_revision
        }
      }
    })
  end

  defp accepted_audit_attrs(packet, authority_packet) do
    %{
      tenant_id: packet.tenant_id,
      installation_id: packet.installation_id,
      subject_id: packet.subject_id,
      execution_id: packet.execution_id,
      trace_id: packet.substrate_trace_id,
      decision_hash: authority_packet.decision_hash,
      fact_kind: :substrate_governance_accepted
    }
  end

  defp rejection_result(packet, %DecisionRejection{} = rejection) do
    %{
      class: rejection_class(rejection),
      terminal?: rejection.retryability == :terminal,
      decision_hash: nil,
      audit_attrs: %{
        tenant_id: packet.tenant_id,
        installation_id: packet.installation_id,
        subject_id: packet.subject_id,
        execution_id: packet.execution_id,
        trace_id: packet.substrate_trace_id,
        rejection_id: rejection.rejection_id,
        rejection_reason: rejection.reason_code,
        rejection_summary: rejection.summary,
        retryability: rejection.retryability,
        publication_requirement: rejection.publication_requirement,
        fact_kind: :substrate_governance_rejected
      },
      operator_message: rejection.summary,
      rejection_classification: DecisionRejection.dump(rejection)
    }
  end

  defp authorization_rejection_result(packet, reason_code, metadata) when is_map(metadata) do
    %{
      class: :auth_error,
      terminal?: true,
      decision_hash: nil,
      audit_attrs:
        %{
          tenant_id: packet.tenant_id,
          installation_id: packet.installation_id,
          subject_id: packet.subject_id,
          execution_id: packet.execution_id,
          trace_id: packet.substrate_trace_id,
          rejection_id: "rejection/#{packet.execution_id}/#{reason_code}",
          rejection_reason: reason_code,
          rejection_summary: reason_code,
          retryability: :terminal,
          publication_requirement: :host_and_substrate,
          fact_kind: :substrate_governance_rejected
        }
        |> Map.merge(metadata),
      operator_message: reason_code,
      rejection_classification: %{
        rejection_id: "rejection/#{packet.execution_id}/#{reason_code}",
        stage: :authorization,
        reason_code: reason_code,
        summary: reason_code,
        retryability: :terminal,
        publication_requirement: :host_and_substrate,
        extensions: metadata
      }
    }
  end

  defp validation_audit_attrs(packet, error) when is_map(packet) do
    %{
      tenant_id: Map.get(packet, :tenant_id) || Map.get(packet, "tenant_id"),
      installation_id: Map.get(packet, :installation_id) || Map.get(packet, "installation_id"),
      subject_id: Map.get(packet, :subject_id) || Map.get(packet, "subject_id"),
      execution_id: Map.get(packet, :execution_id) || Map.get(packet, "execution_id"),
      trace_id: Map.get(packet, :substrate_trace_id) || Map.get(packet, "substrate_trace_id"),
      error: Exception.message(error),
      fact_kind: :substrate_governance_validation_failed
    }
  end

  defp rejection_class(%DecisionRejection{stage: stage}) when stage in [:auth, :authorization],
    do: :auth_error

  defp rejection_class(%DecisionRejection{stage: :semantic}), do: :semantic_failure
  defp rejection_class(%DecisionRejection{}), do: :policy_error

  defp classify_rejection!(packet, selection, reason_code) do
    causes = rejection_causes(packet, selection, reason_code)

    DecisionRejectionClassifier.classify!(
      %{
        rejection_id: "rejection/#{packet.execution_id}/#{reason_code}",
        stage: :planning,
        reason_code: reason_code,
        summary: rejection_summary(reason_code),
        causes: causes,
        extensions: %{
          "execution_id" => packet.execution_id,
          "trace_id" => packet.substrate_trace_id,
          "ingress_kind" => "substrate_origin"
        }
      },
      selection
    )
  end

  defp rejection_causes(_packet, %Selection{} = selection, reason_code) do
    policy_reasons = selection.rejection_policy

    causes =
      []
      |> reject_if_not_relevant(
        :governance,
        reason_code,
        policy_reasons.governance_change_reason_codes
      )
      |> reject_if_not_relevant(
        :runtime_state,
        reason_code,
        policy_reasons.runtime_change_reason_codes
      )
      |> reject_if_not_relevant(
        :runtime_state,
        reason_code,
        policy_reasons.derived_state_reason_codes
      )
      |> reject_if_not_relevant(
        :policy_denial,
        reason_code,
        policy_reasons.denial_audit_reason_codes
      )

    if causes == [] do
      [:input]
    else
      Enum.uniq(causes)
    end
  end

  defp reject_if_not_relevant(causes, cause, reason_code, listed_codes) do
    if reason_code in listed_codes do
      [cause | causes]
    else
      causes
    end
  end

  defp rejection_summary("missing_scope_selector"),
    do: "substrate ingress requires at least one scope selector"

  defp rejection_summary("missing_target_hint"),
    do: "substrate ingress requires at least one target hint"

  defp rejection_summary("missing_candidate_step"),
    do: "substrate ingress requires at least one candidate step"

  defp rejection_summary("missing_execution_intent"),
    do: "candidate step is missing execution intent details"

  defp rejection_summary("invalid_execution_intent"),
    do: "candidate step execution intent must be a JSON object"

  defp rejection_summary("unsupported_execution_intent_family"),
    do: "candidate step requests an unsupported execution family"

  defp rejection_summary("missing_target_id"), do: "substrate ingress requires a target identity"
  defp rejection_summary(reason_code), do: reason_code

  defp logical_workspace_ref(%ScopeSelector{} = selector) do
    cond do
      is_binary(selector.scope_id) and selector.scope_id != "" and
          String.starts_with?(selector.scope_id, "workspace://") ->
        selector.scope_id

      is_binary(selector.scope_id) and selector.scope_id != "" ->
        "workspace://#{selector.scope_kind}/#{selector.scope_id}"

      is_binary(selector.workspace_root) and selector.workspace_root != "" ->
        "workspace://#{selector.scope_kind}/#{Path.basename(selector.workspace_root)}"

      true ->
        raise ArgumentError,
              "substrate ingress compilation requires scope selector scope_id or workspace_root"
    end
  end

  defp sandbox_level(step_extensions, %CandidateStep{} = candidate_step, selection) do
    case Map.get(step_extensions, "sandbox_level") do
      value when value in @allowed_sandbox_levels ->
        value

      _other ->
        cond do
          Enum.any?(candidate_step.allowed_operations, &String.contains?(&1, "write")) -> "strict"
          selection.profiles.approval_profile in ["manual", "approval_required"] -> "strict"
          true -> "standard"
        end
    end
  end

  defp sandbox_egress(step_extensions, fallback) do
    case Map.get(step_extensions, "sandbox_egress", fallback) do
      value when value in @allowed_egress_policies -> value
      _value -> "restricted"
    end
  end

  defp sandbox_approvals(step_extensions, approval_profile) do
    case Map.get(step_extensions, "sandbox_approvals") do
      value when value in @allowed_approval_modes ->
        value

      _other when approval_profile in ["manual", "approval_required"] ->
        "manual"

      _other when approval_profile in ["none", "approval_none"] ->
        "none"

      _other ->
        "auto"
    end
  end

  defp acceptable_attestation(step_extensions, policy) do
    default =
      case policy do
        %ExecutionPolicy{acceptable_attestation: values} -> values
        _other -> ["local-erlexec-weak"]
      end

    step_extensions
    |> Map.get("acceptable_attestation", default)
    |> normalize_string_list()
    |> case do
      [] -> default
      values -> values
    end
  end

  defp workspace_mutability(step_extensions, %CandidateStep{} = candidate_step) do
    case Map.get(step_extensions, "workspace_mutability") do
      value when value in @allowed_workspace_mutabilities ->
        value

      _other ->
        if Enum.any?(candidate_step.allowed_operations, fn operation ->
             String.contains?(operation, "write") or String.contains?(operation, "patch")
           end) do
          "read_write"
        else
          "read_only"
        end
    end
  end

  defp execution_family(step_extensions, fallback) do
    case Map.get(step_extensions, "execution_family", fallback) do
      value when value in @allowed_execution_families -> value
      _other -> fallback
    end
  end

  defp placement_intent(step_extensions) do
    case Map.get(step_extensions, "placement_intent", @default_placement_intent) do
      value when value in @allowed_placement_intents -> value
      _other -> @default_placement_intent
    end
  end

  defp effect_classes(step_extensions, %CandidateStep{} = candidate_step) do
    case Map.get(step_extensions, "effect_classes") do
      value when is_list(value) ->
        normalize_string_list(value)

      _other ->
        infer_effect_classes(candidate_step.allowed_operations)
    end
  end

  defp infer_effect_classes(allowed_operations) do
    classes =
      Enum.reduce(allowed_operations, [], fn operation, acc ->
        acc
        |> maybe_prepend(
          "filesystem",
          String.contains?(operation, "write") or String.contains?(operation, "patch")
        )
        |> maybe_prepend("process", String.contains?(operation, "exec"))
      end)

    Enum.reverse(classes)
  end

  defp selected_step_id(packet, %CandidateStep{} = candidate_step) do
    case Map.get(candidate_step.extensions, "step_id") ||
           Map.get(candidate_step.extensions, :step_id) do
      value when is_binary(value) and value != "" -> value
      _other -> "step/#{packet.execution_id}/#{candidate_step.capability_id}"
    end
  end

  defp downstream_scope(step_extensions, execution_intent_family, target_kind) do
    Map.get(step_extensions, "downstream_scope", "#{execution_intent_family}:#{target_kind}")
  end

  defp preferred_topology_value(nil, _field), do: nil

  defp preferred_topology_value(preferred_topology, field) do
    preferred_topology
    |> Map.get(field)
    |> case do
      nil -> nil
      value when is_atom(value) -> Atom.to_string(value)
      value -> value
    end
  end

  defp preferred_topology_routing_hints(nil), do: %{}

  defp preferred_topology_routing_hints(preferred_topology) do
    Map.get(preferred_topology, :routing_hints, %{})
  end

  defp normalize_string_list(value) when is_list(value) do
    value
    |> Enum.flat_map(fn
      item when is_binary(item) and item != "" -> [item]
      _other -> []
    end)
    |> Enum.uniq()
  end

  defp normalize_string_list(_value), do: []

  defp string_list!(value) when is_list(value) do
    Enum.map(value, fn
      item when is_binary(item) and item != "" ->
        item

      item ->
        raise ArgumentError,
              "substrate ingress string list contains invalid item: #{inspect(item)}"
    end)
  end

  defp string_list!(other),
    do: raise(ArgumentError, "substrate ingress expected a string list, got: #{inspect(other)}")

  defp normalize_optional_string(nil), do: nil
  defp normalize_optional_string(value) when is_binary(value) and value != "", do: value
  defp normalize_optional_string(_other), do: nil

  defp maybe_put_execution_envelope(extensions, %{"execution_envelope" => %{} = envelope}) do
    Map.put(extensions, "execution_envelope", envelope)
  end

  defp maybe_put_execution_envelope(extensions, %{execution_envelope: %{} = envelope}) do
    Map.put(extensions, "execution_envelope", envelope)
  end

  defp maybe_put_execution_envelope(extensions, _step_extensions), do: extensions

  defp normalize_optional_non_neg_integer(nil), do: nil
  defp normalize_optional_non_neg_integer(value) when is_integer(value) and value >= 0, do: value
  defp normalize_optional_non_neg_integer(_other), do: nil

  defp maybe_prepend(list, _value, false), do: list

  defp maybe_prepend(list, value, true) do
    if value in list do
      list
    else
      [value | list]
    end
  end

  defp metadata_keys(metadata) do
    metadata
    |> Map.keys()
    |> Enum.map(&to_string/1)
    |> Enum.sort()
  end

  defp required_string!(map, key) do
    case Map.get(map, key) || Map.get(map, Atom.to_string(key)) do
      value when is_binary(value) and value != "" ->
        value

      other ->
        raise ArgumentError,
              "substrate ingress #{key} must be a non-empty string, got: #{inspect(other)}"
    end
  end

  defp optional_string(map, key) do
    case Map.get(map, key) || Map.get(map, Atom.to_string(key)) do
      value when is_binary(value) and value != "" -> value
      _other -> nil
    end
  end

  defp required_revision!(map) do
    case Map.get(map, :installation_revision) || Map.get(map, "installation_revision") do
      value when is_integer(value) and value >= 0 ->
        value

      other ->
        raise ArgumentError,
              "substrate ingress installation_revision must be a non-negative integer, got: #{inspect(other)}"
    end
  end

  defp optional_non_neg_integer(map, key) do
    case Map.get(map, key) || Map.get(map, Atom.to_string(key)) do
      value when is_integer(value) and value >= 0 -> value
      _other -> nil
    end
  end

  defp json_object!(map, key) do
    case Map.get(map, key) || Map.get(map, Atom.to_string(key)) do
      value when is_map(value) ->
        value

      other ->
        raise ArgumentError, "substrate ingress #{key} must be a map, got: #{inspect(other)}"
    end
  end

  defp required_map!(map, key), do: json_object!(map, key)
end
