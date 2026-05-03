defmodule Citadel.Apps.HostSurfaceHarness do
  @moduledoc """
  Thin proof harness for the host/kernel seam above Citadel.

  The harness keeps Citadel's request boundary at structured `IntentEnvelope`
  values, optionally resolves raw host input through an explicit resolver seam,
  records synchronous `DecisionRejection` outcomes through the continuity
  owner, and exposes strict dead-letter maintenance through explicit host-facing
  wrappers instead of hidden runtime shortcuts.
  """

  alias Citadel.ActionOutboxEntry
  alias Citadel.BackoffPolicy
  alias Citadel.DecisionRejection
  alias Citadel.DecisionRejectionClassifier
  alias Citadel.IntentEnvelope
  alias Citadel.IntentEnvelope.Constraints
  alias Citadel.IntentEnvelope.DesiredOutcome
  alias Citadel.IntentEnvelope.RiskHint
  alias Citadel.IntentEnvelope.ScopeSelector
  alias Citadel.IntentEnvelope.SuccessCriterion
  alias Citadel.IntentEnvelope.TargetHint
  alias Citadel.IntentMappingConstraints
  alias Citadel.LocalAction
  alias Citadel.PersistedSessionBlob
  alias Citadel.PersistedSessionEnvelope
  alias Citadel.PolicyPacks
  alias Citadel.PolicyPacks.PolicyPack
  alias Citadel.PolicyPacks.Selection
  alias Citadel.ProjectionBridge
  alias Citadel.ResolutionProvenance
  alias Citadel.Kernel.SessionDirectory
  alias Citadel.Kernel.SessionServer
  alias Citadel.Kernel.SystemClock
  alias Citadel.ScopeRef
  alias Citadel.SessionContinuityCommit
  alias Citadel.SignalBridge
  alias Jido.Integration.V2.DerivedStateAttachment
  alias Jido.Integration.V2.ReviewProjection

  @manifest %{
    package: :citadel_host_surface_harness,
    layer: :app,
    status: :wave_7_host_surface_proof,
    owns: [
      :host_kernel_seam_proofs,
      :structured_ingress,
      :multi_session_probes,
      :explicit_host_dead_letter_surfaces
    ],
    internal_dependencies: [
      :citadel_governance,
      :citadel_policy_packs,
      :citadel_kernel,
      :citadel_signal_bridge,
      :citadel_projection_bridge,
      :citadel_boundary_bridge,
      :citadel_trace_bridge
    ],
    external_dependencies: []
  }

  @typedoc """
  Thin app composition state carrying only public runtime and bridge seams.
  """
  @type t :: %__MODULE__{
          session_directory: GenServer.server(),
          signal_bridge: SignalBridge.t(),
          projection_bridge: ProjectionBridge.t() | nil,
          policy_packs: [PolicyPack.t()],
          policy_snapshot: (-> {:ok, map()} | {:error, term()}),
          intent_resolver: module() | nil,
          lookup_session: (String.t() -> {:ok, pid()} | {:error, term()}),
          clock: module()
        }

  @type submission_result ::
          {:accepted, map(), t()}
          | {:rejected, map(), t()}
          | {:error, term(), t()}

  defstruct session_directory: SessionDirectory,
            signal_bridge: nil,
            projection_bridge: nil,
            policy_packs: [],
            policy_snapshot: nil,
            intent_resolver: nil,
            lookup_session: &Citadel.Kernel.lookup_session/1,
            clock: SystemClock

  @spec proof_focus() :: [atom()]
  def proof_focus do
    [:structured_ingress, :multi_session_behavior, :multi_ingress_behavior, :host_kernel_boundary]
  end

  @spec manifest() :: map()
  def manifest, do: @manifest

  @spec new!(keyword()) :: t()
  def new!(opts) do
    signal_bridge =
      case Keyword.fetch(opts, :signal_bridge) do
        {:ok, %SignalBridge{} = bridge} ->
          bridge

        {:ok, other} ->
          raise ArgumentError,
                "signal_bridge must be a Citadel.SignalBridge, got: #{inspect(other)}"

        :error ->
          raise ArgumentError, "signal_bridge is required"
      end

    projection_bridge =
      case Keyword.get(opts, :projection_bridge) do
        nil ->
          nil

        %ProjectionBridge{} = bridge ->
          bridge

        other ->
          raise ArgumentError,
                "projection_bridge must be a Citadel.ProjectionBridge, got: #{inspect(other)}"
      end

    intent_resolver = Keyword.get(opts, :intent_resolver)

    if intent_resolver &&
         not (is_atom(intent_resolver) and function_exported?(intent_resolver, :resolve_intent, 1)) do
      raise ArgumentError,
            "intent_resolver must export resolve_intent/1 when configured, got: #{inspect(intent_resolver)}"
    end

    lookup_session = Keyword.get(opts, :lookup_session, &Citadel.Kernel.lookup_session/1)

    unless is_function(lookup_session, 1) do
      raise ArgumentError, "lookup_session must be an arity-1 function"
    end

    policy_snapshot = Keyword.get(opts, :policy_snapshot, fn -> runtime_policy_snapshot() end)

    unless is_function(policy_snapshot, 0) do
      raise ArgumentError, "policy_snapshot must be an arity-0 function"
    end

    clock = Keyword.get(opts, :clock, SystemClock)

    unless is_atom(clock) and function_exported?(clock, :utc_now, 0) do
      raise ArgumentError, "clock must export utc_now/0"
    end

    %__MODULE__{
      session_directory: Keyword.get(opts, :session_directory, SessionDirectory),
      signal_bridge: signal_bridge,
      projection_bridge: projection_bridge,
      policy_packs: Enum.map(Keyword.get(opts, :policy_packs, []), &PolicyPack.new!/1),
      policy_snapshot: policy_snapshot,
      intent_resolver: intent_resolver,
      lookup_session: lookup_session,
      clock: clock
    }
  end

  @spec submit_envelope(t(), IntentEnvelope.t() | map() | keyword(), map() | keyword(), keyword()) ::
          submission_result()
  def submit_envelope(%__MODULE__{} = harness, envelope, context, opts \\ []) do
    envelope = normalize_envelope!(envelope)
    context = normalize_request_context!(context)
    do_submit_envelope(harness, envelope, context, :direct_intent_envelope, opts)
  end

  @spec submit_resolved_input(t(), term(), map() | keyword(), keyword()) :: submission_result()
  def submit_resolved_input(harness, raw_input, context, opts \\ [])

  def submit_resolved_input(
        %__MODULE__{intent_resolver: nil} = harness,
        _raw_input,
        _context,
        _opts
      ) do
    {:error, :intent_resolver_not_configured, harness}
  end

  def submit_resolved_input(%__MODULE__{} = harness, raw_input, context, opts) do
    context = normalize_request_context!(context)

    case harness.intent_resolver.resolve_intent(raw_input) do
      {:ok, resolved_envelope} ->
        resolved_envelope = normalize_envelope!(resolved_envelope)
        do_submit_envelope(harness, resolved_envelope, context, :resolved_input, opts)

      {:error, reason} ->
        {:error, {:intent_resolution_failed, reason}, harness}
    end
  end

  @spec deliver_signal(t(), String.t(), term()) ::
          {:ok, map(), t()} | {:error, term(), t()}
  def deliver_signal(%__MODULE__{} = harness, session_id, raw_signal)
      when is_binary(session_id) do
    case SignalBridge.normalize_signal(harness.signal_bridge, raw_signal) do
      {:ok, observation, signal_bridge} ->
        if observation.session_id != session_id do
          {:error, :session_mismatch, %{harness | signal_bridge: signal_bridge}}
        else
          case harness.lookup_session.(session_id) do
            {:ok, session_server} ->
              case record_runtime_observation_with_live_owner(session_server, observation) do
                :ok ->
                  {:ok, %{session_id: session_id, signal_id: observation.signal_id},
                   %{harness | signal_bridge: signal_bridge}}

                {:error, reason} ->
                  {:error, reason, %{harness | signal_bridge: signal_bridge}}
              end

            {:error, reason} ->
              {:error, reason, %{harness | signal_bridge: signal_bridge}}
          end
        end

      {:error, reason, signal_bridge} ->
        {:error, reason, %{harness | signal_bridge: signal_bridge}}
    end
  end

  @spec inspect_session(t(), String.t()) :: map()
  def inspect_session(%__MODULE__{} = harness, session_id) do
    SessionDirectory.inspect_session(harness.session_directory, session_id)
  end

  @spec clear_dead_letter(t(), String.t(), String.t()) ::
          {:ok, PersistedSessionBlob.t()} | {:error, term()}
  def clear_dead_letter(%__MODULE__{} = harness, entry_id, override_reason) do
    SessionDirectory.clear_dead_letter(harness.session_directory, entry_id, override_reason)
  end

  @spec replace_dead_letter(
          t(),
          String.t(),
          ActionOutboxEntry.t() | map() | keyword(),
          String.t()
        ) ::
          {:ok, PersistedSessionBlob.t()} | {:error, term()}
  def replace_dead_letter(%__MODULE__{} = harness, entry_id, replacement_entry, override_reason) do
    SessionDirectory.replace_dead_letter(
      harness.session_directory,
      entry_id,
      ActionOutboxEntry.new!(replacement_entry),
      override_reason
    )
  end

  @spec retry_dead_letter_with_override(t(), String.t(), String.t(), keyword()) ::
          {:ok, PersistedSessionBlob.t()} | {:error, term()}
  def retry_dead_letter_with_override(
        %__MODULE__{} = harness,
        entry_id,
        override_reason,
        opts \\ []
      ) do
    SessionDirectory.retry_dead_letter_with_override(
      harness.session_directory,
      entry_id,
      override_reason,
      opts
    )
  end

  @spec bulk_recover_dead_letters(t(), keyword(), term()) :: {:ok, non_neg_integer()}
  def bulk_recover_dead_letters(%__MODULE__{} = harness, selector, operation) do
    SessionDirectory.bulk_recover_dead_letters(harness.session_directory, selector, operation)
  end

  @spec quarantine_session(t(), String.t(), String.t(), keyword()) :: :ok
  def quarantine_session(%__MODULE__{} = harness, session_id, reason_family, opts \\ []) do
    SessionDirectory.quarantine_session(
      harness.session_directory,
      session_id,
      reason_family,
      opts
    )
  end

  @spec quarantined_sessions(t()) :: map()
  def quarantined_sessions(%__MODULE__{} = harness) do
    SessionDirectory.quarantined_sessions(harness.session_directory)
  end

  @spec force_evict_quarantined(t(), String.t()) :: :ok | {:error, :not_quarantined}
  def force_evict_quarantined(%__MODULE__{} = harness, session_id) do
    SessionDirectory.force_evict_quarantined(harness.session_directory, session_id)
  end

  @spec valid_direct_envelope(map() | keyword()) :: IntentEnvelope.t()
  def valid_direct_envelope(overrides \\ %{}) do
    base_envelope_attrs()
    |> deep_merge(Map.new(overrides))
    |> IntentEnvelope.new!()
  end

  @spec unplannable_direct_envelope(map() | keyword()) :: IntentEnvelope.t()
  def unplannable_direct_envelope(overrides \\ %{}) do
    base_envelope_attrs()
    |> deep_merge(%{
      constraints: %{
        boundary_requirement: :reuse_existing,
        allowed_boundary_classes: ["workspace_session"],
        allowed_service_ids: ["svc.compiler"],
        forbidden_service_ids: [],
        max_steps: 2,
        review_required: false,
        extensions: %{}
      },
      target_hints: [
        %{
          target_kind: "workspace",
          preferred_target_id: "workspace/main",
          preferred_service_id: "svc.compiler",
          preferred_boundary_class: "workspace_session",
          session_mode_preference: :detached,
          coordination_mode_preference: :single_target,
          routing_tags: ["primary"],
          extensions: %{}
        }
      ]
    })
    |> deep_merge(Map.new(overrides))
    |> IntentEnvelope.new!()
  end

  defp do_submit_envelope(harness, envelope, context, ingress_path, opts) do
    selection = select_policy!(harness, envelope, context)

    case IntentMappingConstraints.planning_status(envelope) do
      :plannable ->
        accept_envelope(harness, envelope, context, selection, ingress_path, opts)

      {:unplannable, default_reason_code} ->
        reject_envelope(
          harness,
          envelope,
          context,
          selection,
          ingress_path,
          default_reason_code,
          opts
        )
    end
  end

  defp accept_envelope(harness, envelope, context, selection, ingress_path, opts) do
    claim_opts =
      opts
      |> Keyword.get(:claim_opts, [])
      |> Keyword.put_new(:scope_ref, scope_ref_from_envelope(envelope, context))
      |> Keyword.put_new(:extensions, host_extensions(context, ingress_path))

    case harness.lookup_session.(context.session_id) do
      {:ok, session_server} ->
        case record_acceptance_with_live_owner(session_server) do
          {:ok, session_state} ->
            {:accepted,
             %{
               request_id: context.request_id,
               session_id: context.session_id,
               trace_id: context.trace_id,
               lifecycle_event: :live_owner,
               continuity_revision: session_state.continuity_revision,
               policy_pack_id: selection.pack_id,
               ingress_path: ingress_path
             }, harness}

          {:error, :not_found} ->
            accept_without_live_owner(harness, context, selection, ingress_path, claim_opts)

          {:error, reason} ->
            {:error, reason, harness}
        end

      {:error, :not_found} ->
        accept_without_live_owner(harness, context, selection, ingress_path, claim_opts)

      {:error, reason} ->
        {:error, reason, harness}
    end
  end

  defp accept_without_live_owner(harness, context, selection, ingress_path, claim_opts) do
    case SessionDirectory.claim_session(harness.session_directory, context.session_id, claim_opts) do
      {:ok, %{blob: blob, lifecycle_event: lifecycle_event}} ->
        {:accepted,
         %{
           request_id: context.request_id,
           session_id: context.session_id,
           trace_id: context.trace_id,
           lifecycle_event: lifecycle_event,
           continuity_revision: blob.envelope.continuity_revision,
           policy_pack_id: selection.pack_id,
           ingress_path: ingress_path
         }, harness}

      {:error, reason} ->
        {:error, reason, harness}
    end
  end

  defp reject_envelope(
         harness,
         envelope,
         context,
         selection,
         ingress_path,
         default_reason_code,
         opts
       ) do
    claim_opts =
      opts
      |> Keyword.get(:claim_opts, [])
      |> Keyword.put_new(:scope_ref, scope_ref_from_envelope(envelope, context))
      |> Keyword.put_new(:extensions, host_extensions(context, ingress_path))

    rejection = classify_rejection!(context, selection, default_reason_code, opts)

    with {:ok, persistence_result} <-
           persist_rejection(harness, context.session_id, rejection, claim_opts) do
      {publication, harness} =
        maybe_publish_rejection(harness, rejection, selection, context)

      {:rejected,
       %{
         request_id: context.request_id,
         session_id: context.session_id,
         trace_id: context.trace_id,
         lifecycle_event: persistence_result.lifecycle_event,
         continuity_revision: persistence_result.continuity_revision,
         ingress_path: ingress_path,
         rejection: rejection,
         publication: publication,
         classification_posture: DecisionRejection.classification_posture()
       }, harness}
    else
      {:error, reason} -> {:error, reason, harness}
    end
  end

  defp persist_rejection(harness, session_id, rejection, claim_opts) do
    case harness.lookup_session.(session_id) do
      {:ok, session_server} ->
        case record_rejection_with_live_owner(session_server, rejection) do
          {:ok, session_state} ->
            {:ok,
             %{
               lifecycle_event: :live_owner,
               continuity_revision: session_state.continuity_revision
             }}

          {:error, :not_found} ->
            persist_rejection_without_live_owner(harness, session_id, rejection, claim_opts)

          {:error, reason} ->
            {:error, reason}
        end

      {:error, :not_found} ->
        persist_rejection_without_live_owner(harness, session_id, rejection, claim_opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp persist_rejection_without_live_owner(harness, session_id, rejection, claim_opts) do
    with {:ok, %{blob: claimed_blob, lifecycle_event: lifecycle_event}} <-
           SessionDirectory.claim_session(
             harness.session_directory,
             session_id,
             claim_opts
           ),
         {:ok, committed_blob} <- commit_rejection(harness, claimed_blob, rejection) do
      {:ok,
       %{
         lifecycle_event: lifecycle_event,
         continuity_revision: committed_blob.envelope.continuity_revision
       }}
    end
  end

  defp record_rejection_with_live_owner(session_server, rejection) do
    SessionServer.record_rejection(session_server, rejection)
  catch
    :exit, {:noproc, _details} -> {:error, :not_found}
    :exit, :noproc -> {:error, :not_found}
    :exit, reason -> {:error, reason}
  end

  defp record_acceptance_with_live_owner(session_server) do
    SessionServer.record_host_acceptance(session_server)
  catch
    :exit, {:noproc, _details} -> {:error, :not_found}
    :exit, :noproc -> {:error, :not_found}
    :exit, reason -> {:error, reason}
  end

  defp record_runtime_observation_with_live_owner(session_server, observation) do
    SessionServer.record_runtime_observation(session_server, observation)
  catch
    :exit, {:noproc, _details} -> {:error, :not_found}
    :exit, :noproc -> {:error, :not_found}
    :exit, reason -> {:error, reason}
  end

  defp classify_rejection!(context, %Selection{} = selection, default_reason_code, opts) do
    override = Map.new(Keyword.get(opts, :rejection, %{}))
    reason_code = Map.get(override, :reason_code, default_reason_code)

    DecisionRejectionClassifier.classify!(
      %{
        rejection_id:
          Map.get(override, :rejection_id, "rejection/#{context.request_id}/#{reason_code}"),
        stage: Map.get(override, :stage, :planning),
        reason_code: reason_code,
        summary: Map.get(override, :summary, default_rejection_summary(reason_code)),
        causes: Map.get(override, :causes, default_rejection_causes(reason_code)),
        extensions:
          Map.merge(
            %{
              "request_id" => context.request_id,
              "session_id" => context.session_id,
              "trace_id" => context.trace_id
            },
            Map.get(override, :extensions, %{})
          )
      },
      selection
    )
  end

  defp commit_rejection(
         harness,
         %PersistedSessionBlob{} = claimed_blob,
         %DecisionRejection{} = rejection
       ) do
    next_blob =
      PersistedSessionBlob.new!(%{
        schema_version: PersistedSessionBlob.schema_version(),
        session_id: claimed_blob.session_id,
        envelope:
          claimed_blob.envelope
          |> PersistedSessionEnvelope.dump()
          |> Map.merge(%{
            continuity_revision: claimed_blob.envelope.continuity_revision + 1,
            last_active_at: harness.clock.utc_now(),
            last_rejection: rejection
          })
          |> PersistedSessionEnvelope.new!(),
        outbox_entries: claimed_blob.outbox_entries,
        extensions: claimed_blob.extensions
      })

    commit =
      SessionContinuityCommit.new!(%{
        session_id: claimed_blob.session_id,
        expected_continuity_revision: claimed_blob.envelope.continuity_revision,
        expected_owner_incarnation: claimed_blob.envelope.owner_incarnation,
        persisted_blob: next_blob,
        extensions: %{}
      })

    case SessionDirectory.commit_continuity(harness.session_directory, commit) do
      {:ok, committed_blob} -> {:ok, committed_blob}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_publish_rejection(
         harness,
         %DecisionRejection{publication_requirement: :host_only},
         _selection,
         _context
       ) do
    {%{status: :host_only, packet_kind: nil, receipt_ref: nil}, harness}
  end

  defp maybe_publish_rejection(
         %__MODULE__{projection_bridge: nil} = harness,
         %DecisionRejection{} = rejection,
         _selection,
         _context
       ) do
    {%{
       status: :publication_required_but_bridge_missing,
       packet_kind: rejection.publication_requirement,
       receipt_ref: nil
     }, harness}
  end

  defp maybe_publish_rejection(
         %__MODULE__{projection_bridge: %ProjectionBridge{}} = harness,
         %DecisionRejection{} = rejection,
         %Selection{} = selection,
         context
       ) do
    entry = rejection_publication_entry(rejection, context, harness.clock.utc_now())

    case rejection.publication_requirement do
      :review_projection ->
        payload = review_projection_for_rejection(rejection, selection, context)

        case ProjectionBridge.publish_review_projection(harness.projection_bridge, payload, entry) do
          {:ok, receipt_ref, projection_bridge} ->
            {%{status: :published, packet_kind: :review_projection, receipt_ref: receipt_ref},
             %{harness | projection_bridge: projection_bridge}}

          {:error, reason, projection_bridge} ->
            {%{
               status: {:publication_failed, reason},
               packet_kind: :review_projection,
               receipt_ref: nil
             }, %{harness | projection_bridge: projection_bridge}}
        end

      :derived_state_attachment ->
        payload = derived_state_attachment_for_rejection(rejection, selection, context)

        case ProjectionBridge.publish_derived_state_attachment(
               harness.projection_bridge,
               payload,
               entry
             ) do
          {:ok, receipt_ref, projection_bridge} ->
            {%{
               status: :published,
               packet_kind: :derived_state_attachment,
               receipt_ref: receipt_ref
             }, %{harness | projection_bridge: projection_bridge}}

          {:error, reason, projection_bridge} ->
            {%{
               status: {:publication_failed, reason},
               packet_kind: :derived_state_attachment,
               receipt_ref: nil
             }, %{harness | projection_bridge: projection_bridge}}
        end
    end
  end

  defp review_projection_for_rejection(rejection, selection, context) do
    subject = host_subject(context)
    evidence_ref = rejection_evidence_ref(rejection, context)

    ReviewProjection.new!(%{
      schema_version: "review_projection.v1",
      projection: "citadel.decision_rejection",
      packet_ref: rejection_packet_ref(rejection),
      subject: subject,
      selected_attempt: rejection_attempt_subject(rejection),
      evidence_refs: [evidence_ref],
      governance_refs: [
        %{
          kind: :policy_decision,
          id: rejection.rejection_id,
          subject: subject,
          evidence: [evidence_ref],
          metadata: %{
            "policy_pack_id" => selection.pack_id,
            "publication_requirement" => Atom.to_string(rejection.publication_requirement),
            "reason_code" => rejection.reason_code
          }
        }
      ]
    })
  end

  defp derived_state_attachment_for_rejection(rejection, selection, context) do
    DerivedStateAttachment.new!(%{
      subject: host_subject(context),
      evidence_refs: [rejection_evidence_ref(rejection, context)],
      governance_refs: [],
      metadata: %{
        "attachment_kind" => "decision_rejection",
        "policy_pack_id" => selection.pack_id,
        "reason_code" => rejection.reason_code,
        "retryability" => Atom.to_string(rejection.retryability),
        "publication_requirement" => Atom.to_string(rejection.publication_requirement),
        "summary" => rejection.summary
      }
    })
  end

  defp rejection_publication_entry(rejection, context, now) do
    ActionOutboxEntry.new!(%{
      schema_version: ActionOutboxEntry.schema_version(),
      entry_id: "publish/#{rejection.rejection_id}",
      causal_group_id: context.request_id,
      action:
        LocalAction.new!(%{
          action_kind: "publish_decision_rejection",
          payload: %{
            "rejection_id" => rejection.rejection_id,
            "publication_requirement" => Atom.to_string(rejection.publication_requirement)
          },
          extensions: %{}
        }),
      inserted_at: now,
      replay_status: :pending,
      durable_receipt_ref: nil,
      attempt_count: 0,
      max_attempts: 1,
      backoff_policy:
        BackoffPolicy.new!(%{
          strategy: :fixed,
          base_delay_ms: 1,
          max_delay_ms: 1,
          linear_step_ms: nil,
          multiplier: nil,
          jitter_mode: :none,
          jitter_window_ms: 0,
          extensions: %{}
        }),
      next_attempt_at: nil,
      last_error_code: nil,
      dead_letter_reason: nil,
      ordering_mode: :relaxed,
      staleness_mode: :stale_exempt,
      staleness_requirements: nil,
      extensions: %{}
    })
  end

  defp select_policy!(harness, envelope, context) do
    selector = List.first(envelope.scope_selectors)

    policy_packs =
      Enum.map(harness.policy_packs, fn
        %PolicyPack{} = pack -> PolicyPack.dump(pack)
        pack -> pack
      end)

    expected_policy = expected_policy_alignment!(harness, envelope, context)

    policy_packs =
      filter_policy_packs!(
        policy_packs,
        expected_policy.policy_version,
        expected_policy.policy_epoch
      )

    selection =
      PolicyPacks.select_profile!(policy_packs, %{
        tenant_id: context.tenant_id,
        scope_kind: selector.scope_kind,
        environment: selector.environment || Map.get(context, :environment),
        policy_epoch: expected_policy.policy_epoch
      })

    ensure_selection_alignment!(selection, expected_policy)
  end

  defp scope_ref_from_envelope(envelope, context) do
    selector = List.first(envelope.scope_selectors)

    scope_id =
      selector.scope_id ||
        "scope/#{selector.scope_kind}/#{sanitize_workspace_root(selector.workspace_root)}"

    ScopeRef.new!(%{
      scope_id: scope_id,
      scope_kind: selector.scope_kind,
      workspace_root: selector.workspace_root || "/scopes/#{scope_id}",
      environment: selector.environment || Map.get(context, :environment, "unknown"),
      catalog_epoch: 0,
      extensions: %{}
    })
  end

  defp host_extensions(context, ingress_path) do
    %{
      "host_surface_harness" => %{
        "request_id" => context.request_id,
        "trace_id" => context.trace_id,
        "ingress_path" => Atom.to_string(ingress_path)
      }
    }
  end

  defp host_subject(context) do
    %{
      kind: :run,
      id: context.session_id,
      metadata: %{
        "request_id" => context.request_id,
        "trace_id" => context.trace_id,
        "actor_id" => context.actor_id,
        "tenant_id" => context.tenant_id
      }
    }
  end

  defp rejection_attempt_subject(rejection) do
    %{
      kind: :attempt,
      id: rejection.rejection_id,
      metadata: %{
        "stage" => Atom.to_string(rejection.stage),
        "reason_code" => rejection.reason_code
      }
    }
  end

  defp rejection_evidence_ref(rejection, context) do
    %{
      kind: :attempt,
      id: rejection.rejection_id,
      packet_ref: rejection_packet_ref(rejection),
      subject: rejection_attempt_subject(rejection),
      metadata: %{
        "request_id" => context.request_id,
        "session_id" => context.session_id,
        "trace_id" => context.trace_id
      }
    }
  end

  defp rejection_packet_ref(rejection),
    do: "citadel://decision_rejection/#{rejection.rejection_id}"

  defp normalize_request_context!(attrs) do
    attrs = Map.new(attrs)

    %{
      request_id: required_string!(attrs, :request_id),
      session_id: required_string!(attrs, :session_id),
      tenant_id: required_string!(attrs, :tenant_id),
      actor_id: required_string!(attrs, :actor_id),
      trace_id: required_string!(attrs, :trace_id),
      environment: optional_string(attrs, :environment),
      policy_epoch: optional_non_neg_integer(attrs, :policy_epoch)
    }
  end

  defp required_string!(attrs, key) do
    value = Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))

    if is_binary(value) and String.trim(value) != "" do
      value
    else
      raise ArgumentError, "request context #{inspect(key)} must be a non-empty string"
    end
  end

  defp optional_string(attrs, key) do
    value = Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))

    if is_binary(value) and String.trim(value) != "" do
      value
    else
      nil
    end
  end

  defp optional_non_neg_integer(attrs, key) do
    value = Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))

    cond do
      is_nil(value) ->
        nil

      is_integer(value) and value >= 0 ->
        value

      true ->
        raise ArgumentError, "request context #{inspect(key)} must be a non-negative integer"
    end
  end

  defp default_rejection_summary("boundary_reuse_requires_attached_session") do
    "boundary reuse requires an attached session"
  end

  defp default_rejection_summary("inspect_scope_cannot_require_fresh_only_boundary") do
    "scope inspection cannot require a fresh-only boundary"
  end

  defp default_rejection_summary(reason_code) do
    "request rejected: #{reason_code}"
  end

  defp default_rejection_causes("boundary_reuse_requires_attached_session"), do: [:input]
  defp default_rejection_causes("inspect_scope_cannot_require_fresh_only_boundary"), do: [:input]
  defp default_rejection_causes("scope_unavailable"), do: [:runtime_state]
  defp default_rejection_causes("service_hidden"), do: [:runtime_state]
  defp default_rejection_causes("boundary_stale"), do: [:runtime_state]
  defp default_rejection_causes("policy_denied"), do: [:policy_denial]
  defp default_rejection_causes("approval_missing"), do: [:governance]
  defp default_rejection_causes(_reason_code), do: [:planning]

  defp sanitize_workspace_root(nil), do: "default"

  defp sanitize_workspace_root(workspace_root) when is_binary(workspace_root) do
    workspace_root
    |> ascii_alnum_dash()
    |> String.trim("-")
    |> case do
      "" -> "default"
      value -> value
    end
  end

  defp ascii_alnum_dash(value) do
    value
    |> :binary.bin_to_list()
    |> Enum.reduce({[], false}, fn byte, {chars, previous_dash?} ->
      if byte in ?A..?Z or byte in ?a..?z or byte in ?0..?9 do
        {[byte | chars], false}
      else
        if previous_dash?, do: {chars, true}, else: {[?- | chars], true}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
    |> List.to_string()
  end

  defp base_envelope_attrs do
    %{
      intent_envelope_id: "intent/direct/valid",
      scope_selectors: [
        ScopeSelector.new!(%{
          scope_kind: "workspace",
          scope_id: "scope/main",
          workspace_root: "/workspace/main",
          environment: "dev",
          preference: :required,
          extensions: %{}
        })
      ],
      desired_outcome:
        DesiredOutcome.new!(%{
          outcome_kind: :invoke_capability,
          requested_capabilities: ["compile.workspace"],
          result_kind: "workspace_patch",
          subject_selectors: ["primary"],
          extensions: %{}
        }),
      constraints:
        Constraints.new!(%{
          boundary_requirement: :fresh_or_reuse,
          allowed_boundary_classes: ["workspace_session"],
          allowed_service_ids: ["svc.compiler"],
          forbidden_service_ids: [],
          max_steps: 2,
          review_required: false,
          extensions: %{}
        }),
      risk_hints: [
        RiskHint.new!(%{
          risk_code: "writes_workspace",
          severity: :medium,
          requires_governance: false,
          extensions: %{}
        })
      ],
      success_criteria: [
        SuccessCriterion.new!(%{
          criterion_kind: :completion,
          metric: "workspace_patch_applied",
          target: %{"status" => "accepted"},
          required: true,
          extensions: %{}
        })
      ],
      target_hints: [
        TargetHint.new!(%{
          target_kind: "workspace",
          preferred_target_id: "workspace/main",
          preferred_service_id: "svc.compiler",
          preferred_boundary_class: "workspace_session",
          session_mode_preference: :attached,
          coordination_mode_preference: :single_target,
          routing_tags: ["primary"],
          extensions: %{}
        })
      ],
      resolution_provenance:
        ResolutionProvenance.new!(%{
          source_kind: "host_surface_harness",
          resolver_kind: nil,
          resolver_version: nil,
          prompt_version: nil,
          policy_version: "policy-2026-04-09",
          confidence: 1.0,
          ambiguity_flags: [],
          raw_input_refs: [],
          raw_input_hashes: [],
          extensions: %{}
        }),
      extensions: %{}
    }
  end

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      deep_merge(left_value, right_value)
    end)
  end

  defp deep_merge(_left, right), do: right

  defp normalize_envelope!(%IntentEnvelope{} = envelope), do: envelope
  defp normalize_envelope!(envelope), do: IntentEnvelope.new!(envelope)

  defp expected_policy_alignment!(harness, envelope, context) do
    runtime_policy =
      case harness.policy_snapshot.() do
        {:ok, snapshot} -> normalize_policy_snapshot!(snapshot)
        {:error, _reason} -> nil
      end

    provenance_policy_version = envelope.resolution_provenance.policy_version
    context_policy_epoch = context.policy_epoch

    if runtime_policy && provenance_policy_version &&
         runtime_policy.policy_version != provenance_policy_version do
      raise ArgumentError,
            "policy version mismatch between runtime snapshot #{inspect(runtime_policy.policy_version)} and ingress provenance #{inspect(provenance_policy_version)}"
    end

    if runtime_policy && not is_nil(context_policy_epoch) &&
         runtime_policy.policy_epoch != context_policy_epoch do
      raise ArgumentError,
            "policy epoch mismatch between runtime snapshot #{inspect(runtime_policy.policy_epoch)} and request context #{inspect(context_policy_epoch)}"
    end

    %{
      policy_version:
        (runtime_policy && runtime_policy.policy_version) || provenance_policy_version,
      policy_epoch: (runtime_policy && runtime_policy.policy_epoch) || context_policy_epoch
    }
  end

  defp filter_policy_packs!(policy_packs, policy_version, policy_epoch) do
    filtered_packs =
      Enum.filter(policy_packs, fn pack ->
        (is_nil(policy_version) or pack.policy_version == policy_version) and
          (is_nil(policy_epoch) or pack.policy_epoch == policy_epoch)
      end)

    if filtered_packs == [] and (not is_nil(policy_version) or not is_nil(policy_epoch)) do
      raise ArgumentError,
            "no policy pack matched the expected runtime policy alignment version=#{inspect(policy_version)} epoch=#{inspect(policy_epoch)}"
    end

    if filtered_packs == [] do
      policy_packs
    else
      filtered_packs
    end
  end

  defp ensure_selection_alignment!(%Selection{} = selection, expected_policy) do
    if expected_policy.policy_version &&
         selection.policy_version != expected_policy.policy_version do
      raise ArgumentError,
            "selected policy pack version #{inspect(selection.policy_version)} did not match expected version #{inspect(expected_policy.policy_version)}"
    end

    if not is_nil(expected_policy.policy_epoch) &&
         selection.policy_epoch != expected_policy.policy_epoch do
      raise ArgumentError,
            "selected policy pack epoch #{inspect(selection.policy_epoch)} did not match expected epoch #{inspect(expected_policy.policy_epoch)}"
    end

    selection
  end

  defp runtime_policy_snapshot do
    try do
      snapshot = Citadel.Kernel.PolicyCache.peek()

      if snapshot.policy_version == "policy/uninitialized" do
        {:error, :uninitialized}
      else
        {:ok, snapshot}
      end
    catch
      :exit, _reason -> {:error, :not_available}
    end
  end

  defp normalize_policy_snapshot!(snapshot) do
    snapshot = Map.new(snapshot)

    %{
      policy_version: required_string!(snapshot, :policy_version),
      policy_epoch:
        optional_non_neg_integer(snapshot, :policy_epoch) ||
          raise(ArgumentError, "runtime policy snapshot must include policy_epoch")
    }
  end
end
