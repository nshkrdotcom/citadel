defmodule Citadel.Apps.HostSurfaceHarnessTest do
  use ExUnit.Case, async: false

  alias Citadel.ActionOutboxEntry
  alias Citadel.Apps.HostSurfaceHarness
  alias Citadel.BackoffPolicy
  alias Citadel.LocalAction
  alias Citadel.PersistedSessionBlob
  alias Citadel.PersistedSessionEnvelope
  alias Citadel.ProjectionBridge
  alias Citadel.Kernel.BoundaryLeaseTracker
  alias Citadel.Kernel.KernelSnapshot
  alias Citadel.Kernel.ServiceCatalog
  alias Citadel.RuntimeObservation
  alias Citadel.Kernel.SessionDirectory
  alias Citadel.Kernel.SessionServer
  alias Citadel.Kernel.SignalIngress
  alias Citadel.SignalBridge

  defmodule Resolver do
    def resolve_intent(%{"mode" => "resolved"}) do
      {:ok, HostSurfaceHarness.valid_direct_envelope(%{intent_envelope_id: "intent/resolved"})}
    end

    def resolve_intent(_raw_input), do: {:error, :unsupported_shape}
  end

  defmodule ProjectionDownstream do
    def publish_review_projection(projection, metadata) do
      send(
        Process.get(:host_surface_harness_test_pid),
        {:review_projection, projection, metadata}
      )

      {:ok, "review:#{metadata.entry_id}"}
    end

    def publish_derived_state_attachment(attachment, metadata) do
      send(
        Process.get(:host_surface_harness_test_pid),
        {:derived_state_attachment, attachment, metadata}
      )

      {:ok, "attachment:#{metadata.entry_id}"}
    end
  end

  defmodule SignalAdapter do
    def normalize_signal(%{session_id: session_id, signal_id: signal_id, payload: payload}) do
      {:ok,
       RuntimeObservation.new!(%{
         observation_id: "obs/#{signal_id}",
         request_id: "req/#{signal_id}",
         session_id: session_id,
         signal_id: signal_id,
         signal_cursor: "cursor/#{signal_id}",
         runtime_ref_id: "runtime/#{session_id}",
         event_kind: "host_signal",
         event_at: ~U[2026-04-10 10:00:00Z],
         status: "ok",
         output: %{},
         artifacts: [],
         payload: payload,
         subject_ref: %{kind: :run, id: session_id, metadata: %{}},
         evidence_refs: [],
         governance_refs: [],
         extensions: %{
           "tenant_id" => Map.get(payload, "tenant_id", "tenant-1"),
           "authority_scope" => Map.get(payload, "authority_scope", "authority-1"),
           "trace_id" => Map.get(payload, "trace_id", "trace/#{signal_id}"),
           "causation_id" => Map.get(payload, "causation_id", "cause/#{signal_id}"),
           "canonical_idempotency_key" =>
             Map.get(payload, "canonical_idempotency_key", "idem:v1:#{signal_id}")
         }
       })}
    end

    def normalize_signal(_signal), do: {:error, :unsupported_signal}
  end

  defmodule FakeSessionOwner do
    use GenServer

    def start_link(opts \\ []) do
      GenServer.start_link(__MODULE__, :ok, opts)
    end

    def observation_count(server) do
      GenServer.call(server, :observation_count)
    end

    @impl true
    def init(:ok) do
      {:ok, %{observations: []}}
    end

    @impl true
    def handle_call({:record_runtime_observation, observation}, _from, state) do
      {:reply, :ok, %{state | observations: [observation | state.observations]}}
    end

    def handle_call(:observation_count, _from, state) do
      {:reply, length(state.observations), state}
    end
  end

  setup do
    Process.put(:host_surface_harness_test_pid, self())

    kernel_snapshot_name = unique_name(:kernel_snapshot)
    session_directory_name = unique_name(:session_directory)

    start_supervised!({KernelSnapshot, name: kernel_snapshot_name})

    start_supervised!(
      {SessionDirectory, name: session_directory_name, kernel_snapshot: kernel_snapshot_name}
    )

    {:ok,
     kernel_snapshot: kernel_snapshot_name,
     session_directory: session_directory_name,
     signal_bridge: SignalBridge.new!(adapter: SignalAdapter)}
  end

  test "accepts direct IntentEnvelope ingress and the optional resolver seam without making resolver mandatory",
       %{
         session_directory: session_directory,
         signal_bridge: signal_bridge
       } do
    direct_harness =
      HostSurfaceHarness.new!(
        session_directory: session_directory,
        signal_bridge: signal_bridge,
        policy_packs: [policy_pack()]
      )

    assert {:accepted, direct_result, _direct_harness} =
             HostSurfaceHarness.submit_envelope(
               direct_harness,
               HostSurfaceHarness.valid_direct_envelope(),
               request_context("req-direct", "sess-direct")
             )

    assert direct_result.ingress_path == :direct_intent_envelope
    assert direct_result.policy_pack_id == "default"

    resolved_harness =
      HostSurfaceHarness.new!(
        session_directory: session_directory,
        signal_bridge: signal_bridge,
        intent_resolver: Resolver,
        policy_packs: [policy_pack()]
      )

    assert {:accepted, resolved_result, _resolved_harness} =
             HostSurfaceHarness.submit_resolved_input(
               resolved_harness,
               %{"mode" => "resolved"},
               request_context("req-resolved", "sess-resolved")
             )

    assert resolved_result.ingress_path == :resolved_input

    assert %{raw_blob: %PersistedSessionBlob{}} =
             HostSurfaceHarness.inspect_session(direct_harness, "sess-direct")

    assert %{raw_blob: %PersistedSessionBlob{}} =
             HostSurfaceHarness.inspect_session(resolved_harness, "sess-resolved")
  end

  test "returns a synchronous DecisionRejection and records it durably for deliberately unplannable ingress",
       %{
         session_directory: session_directory,
         signal_bridge: signal_bridge
       } do
    harness =
      HostSurfaceHarness.new!(
        session_directory: session_directory,
        signal_bridge: signal_bridge,
        policy_packs: [policy_pack()]
      )

    assert {:rejected, result, _harness} =
             HostSurfaceHarness.submit_envelope(
               harness,
               HostSurfaceHarness.unplannable_direct_envelope(),
               request_context("req-unplannable", "sess-unplannable")
             )

    assert result.rejection.retryability == :after_input_change
    assert result.rejection.publication_requirement == :host_only
    assert result.publication.status == :host_only

    inspected = HostSurfaceHarness.inspect_session(harness, "sess-unplannable")
    assert %PersistedSessionBlob{} = inspected.raw_blob

    assert inspected.raw_blob.envelope.last_rejection.reason_code ==
             "boundary_reuse_requires_attached_session"
  end

  test "routes already-classified rejection publication through review projections and derived-state attachments",
       %{
         session_directory: session_directory,
         signal_bridge: signal_bridge
       } do
    harness =
      HostSurfaceHarness.new!(
        session_directory: session_directory,
        signal_bridge: signal_bridge,
        projection_bridge: ProjectionBridge.new!(downstream: ProjectionDownstream),
        policy_packs: [policy_pack()]
      )

    assert {:rejected, review_result, harness} =
             HostSurfaceHarness.submit_envelope(
               harness,
               HostSurfaceHarness.unplannable_direct_envelope(%{
                 intent_envelope_id: "intent/review"
               }),
               request_context("req-review", "sess-review"),
               rejection: %{
                 reason_code: "policy_denied",
                 summary: "policy denied the request",
                 causes: [:runtime_state, :policy_denial]
               }
             )

    assert review_result.rejection.publication_requirement == :review_projection
    assert review_result.publication.packet_kind == :review_projection

    assert_receive {:review_projection, projection, %{entry_id: entry_id}}
    assert projection.projection == "citadel.decision_rejection"
    assert entry_id == "publish/#{review_result.rejection.rejection_id}"

    assert {:rejected, derived_result, _harness} =
             HostSurfaceHarness.submit_envelope(
               harness,
               HostSurfaceHarness.unplannable_direct_envelope(%{
                 intent_envelope_id: "intent/derived"
               }),
               request_context("req-derived", "sess-derived"),
               rejection: %{
                 reason_code: "planning_failed",
                 summary: "the request is valid but not plannable now",
                 causes: [:planning]
               }
             )

    assert derived_result.rejection.publication_requirement == :derived_state_attachment
    assert derived_result.publication.packet_kind == :derived_state_attachment

    assert_receive {:derived_state_attachment, attachment, %{entry_id: derived_entry_id}}
    assert attachment.metadata["attachment_kind"] == "decision_rejection"
    assert derived_entry_id == "publish/#{derived_result.rejection.rejection_id}"
  end

  test "routes rejection persistence through a live session owner when one exists",
       %{
         kernel_snapshot: kernel_snapshot,
         session_directory: session_directory,
         signal_bridge: signal_bridge
       } do
    service_catalog = unique_name(:service_catalog)
    boundary_tracker = unique_name(:boundary_tracker)
    signal_ingress = unique_name(:signal_ingress)
    invocation_supervisor = unique_name(:invocation_supervisor)
    projection_supervisor = unique_name(:projection_supervisor)
    local_supervisor = unique_name(:local_supervisor)
    session_server = unique_name(:session_server)

    start_supervised!({ServiceCatalog, name: service_catalog, kernel_snapshot: kernel_snapshot})

    start_supervised!(
      {BoundaryLeaseTracker, name: boundary_tracker, kernel_snapshot: kernel_snapshot}
    )

    start_supervised!({Task.Supervisor, name: invocation_supervisor})
    start_supervised!({Task.Supervisor, name: projection_supervisor})
    start_supervised!({Task.Supervisor, name: local_supervisor})

    start_supervised!(
      {SignalIngress,
       name: signal_ingress, session_directory: session_directory, signal_source: SignalAdapter}
    )

    start_supervised!(
      {SessionServer,
       name: session_server,
       session_id: "sess-live",
       session_directory: session_directory,
       kernel_snapshot: kernel_snapshot,
       boundary_lease_tracker: boundary_tracker,
       service_catalog: service_catalog,
       signal_ingress: signal_ingress,
       invocation_supervisor: invocation_supervisor,
       projection_supervisor: projection_supervisor,
       local_supervisor: local_supervisor}
    )

    harness =
      HostSurfaceHarness.new!(
        session_directory: session_directory,
        signal_bridge: signal_bridge,
        policy_packs: [policy_pack()],
        lookup_session: fn
          "sess-live" -> {:ok, session_server}
          _other -> {:error, :not_found}
        end
      )

    assert {:rejected, result, _harness} =
             HostSurfaceHarness.submit_envelope(
               harness,
               HostSurfaceHarness.unplannable_direct_envelope(),
               request_context("req-live", "sess-live")
             )

    assert result.lifecycle_event == :live_owner

    assert {:ok, session_state} =
             SessionServer.commit_transition(session_server, %{
               external_refs: %{"follow_up" => "ok"}
             })

    assert session_state.owner_incarnation == 1
    assert session_state.last_rejection.reason_code == "boundary_reuse_requires_attached_session"

    assert {:ok, persisted_blob} =
             SessionDirectory.fetch_persisted_blob(session_directory, "sess-live")

    assert persisted_blob.envelope.owner_incarnation == 1

    assert persisted_blob.envelope.last_rejection.reason_code ==
             "boundary_reuse_requires_attached_session"
  end

  test "aligns host-surface policy selection with the active runtime snapshot when one is available",
       %{
         session_directory: session_directory,
         signal_bridge: signal_bridge
       } do
    harness =
      HostSurfaceHarness.new!(
        session_directory: session_directory,
        signal_bridge: signal_bridge,
        policy_packs: [policy_pack(), runtime_policy_pack()],
        policy_snapshot: fn ->
          {:ok, %{policy_version: "policy-2026-04-10", policy_epoch: 9}}
        end
      )

    assert {:accepted, result, _harness} =
             HostSurfaceHarness.submit_envelope(
               harness,
               HostSurfaceHarness.valid_direct_envelope(%{
                 resolution_provenance: %{
                   source_kind: "host_surface_harness",
                   policy_version: "policy-2026-04-10",
                   confidence: 1.0,
                   ambiguity_flags: [],
                   raw_input_refs: [],
                   raw_input_hashes: [],
                   extensions: %{}
                 }
               }),
               request_context("req-runtime-policy", "sess-runtime-policy")
             )

    assert result.policy_pack_id == "runtime"
  end

  test "routes accepted ingress through the live session owner without rotating ownership",
       %{
         kernel_snapshot: kernel_snapshot,
         session_directory: session_directory,
         signal_bridge: signal_bridge
       } do
    service_catalog = unique_name(:service_catalog)
    boundary_tracker = unique_name(:boundary_tracker)
    signal_ingress = unique_name(:signal_ingress)
    invocation_supervisor = unique_name(:invocation_supervisor)
    projection_supervisor = unique_name(:projection_supervisor)
    local_supervisor = unique_name(:local_supervisor)
    session_server = unique_name(:session_server)

    start_supervised!({ServiceCatalog, name: service_catalog, kernel_snapshot: kernel_snapshot})

    start_supervised!(
      {BoundaryLeaseTracker, name: boundary_tracker, kernel_snapshot: kernel_snapshot}
    )

    start_supervised!({Task.Supervisor, name: invocation_supervisor})
    start_supervised!({Task.Supervisor, name: projection_supervisor})
    start_supervised!({Task.Supervisor, name: local_supervisor})

    start_supervised!(
      {SignalIngress,
       name: signal_ingress, session_directory: session_directory, signal_source: SignalAdapter}
    )

    start_supervised!(
      {SessionServer,
       name: session_server,
       session_id: "sess-live-accept",
       session_directory: session_directory,
       kernel_snapshot: kernel_snapshot,
       boundary_lease_tracker: boundary_tracker,
       service_catalog: service_catalog,
       signal_ingress: signal_ingress,
       invocation_supervisor: invocation_supervisor,
       projection_supervisor: projection_supervisor,
       local_supervisor: local_supervisor}
    )

    harness =
      HostSurfaceHarness.new!(
        session_directory: session_directory,
        signal_bridge: signal_bridge,
        policy_packs: [policy_pack()],
        lookup_session: fn
          "sess-live-accept" -> {:ok, session_server}
          _other -> {:error, :not_found}
        end
      )

    assert {:accepted, result, _harness} =
             HostSurfaceHarness.submit_envelope(
               harness,
               HostSurfaceHarness.valid_direct_envelope(),
               request_context("req-live-accept", "sess-live-accept")
             )

    assert result.lifecycle_event == :live_owner

    assert {:ok, session_state} =
             SessionServer.commit_transition(session_server, %{
               external_refs: %{"follow_up" => "ok"}
             })

    assert session_state.owner_incarnation == 1

    assert {:ok, persisted_blob} =
             SessionDirectory.fetch_persisted_blob(session_directory, "sess-live-accept")

    assert persisted_blob.envelope.owner_incarnation == 1
  end

  test "delivers observations through the public session API instead of a raw mailbox send",
       %{
         signal_bridge: signal_bridge
       } do
    fake_session = start_supervised!({FakeSessionOwner, name: unique_name(:fake_session_owner)})

    harness =
      HostSurfaceHarness.new!(
        signal_bridge: signal_bridge,
        policy_packs: [policy_pack()],
        lookup_session: fn
          "sess-observation" -> {:ok, fake_session}
          _other -> {:error, :not_found}
        end
      )

    assert {:ok, %{signal_id: "sig-observation"}, _harness} =
             HostSurfaceHarness.deliver_signal(
               harness,
               "sess-observation",
               %{
                 session_id: "sess-observation",
                 signal_id: "sig-observation",
                 payload: %{"kind" => "operator_event"}
               }
             )

    assert FakeSessionOwner.observation_count(fake_session) == 1
  end

  test "exposes strict dead-letter maintenance and selector-based bulk recovery through host-facing wrappers",
       %{
         session_directory: session_directory,
         signal_bridge: signal_bridge
       } do
    harness =
      HostSurfaceHarness.new!(
        session_directory: session_directory,
        signal_bridge: signal_bridge,
        policy_packs: [policy_pack()]
      )

    seed_dead_lettered_session(
      session_directory,
      "sess-one",
      "entry-one",
      "projection_backend_down"
    )

    seed_dead_lettered_session(
      session_directory,
      "sess-two",
      "entry-two",
      "projection_backend_down"
    )

    assert {:ok, 2} =
             HostSurfaceHarness.bulk_recover_dead_letters(
               harness,
               [dead_letter_reason: "projection_backend_down", ordering_mode: :strict],
               {:retry_with_override, "projection sink recovered"}
             )

    inspected_one = HostSurfaceHarness.inspect_session(harness, "sess-one")
    inspected_two = HostSurfaceHarness.inspect_session(harness, "sess-two")

    assert inspected_one.blocked_entries == %{}
    assert inspected_two.blocked_entries == %{}
    assert inspected_one.raw_blob.outbox_entries["entry-one"].replay_status == :pending
    assert inspected_two.raw_blob.outbox_entries["entry-two"].replay_status == :pending
  end

  defp request_context(request_id, session_id) do
    %{
      request_id: request_id,
      session_id: session_id,
      tenant_id: "tenant-1",
      actor_id: "actor-1",
      trace_id: "trace/#{request_id}",
      environment: "dev"
    }
  end

  defp policy_pack do
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
        approval_profile: "standard",
        egress_profile: "restricted",
        workspace_profile: "workspace",
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

  defp runtime_policy_pack do
    policy_pack()
    |> Map.put(:pack_id, "runtime")
    |> Map.put(:policy_version, "policy-2026-04-10")
    |> Map.put(:policy_epoch, 9)
  end

  defp seed_dead_lettered_session(session_directory, session_id, entry_id, dead_letter_reason) do
    entry = dead_letter_entry(entry_id, dead_letter_reason)

    :ok =
      SessionDirectory.seed_raw_blob(
        session_directory,
        session_id,
        PersistedSessionBlob.new!(%{
          schema_version: 1,
          session_id: session_id,
          envelope:
            PersistedSessionEnvelope.new!(%{
              schema_version: 1,
              session_id: session_id,
              continuity_revision: 1,
              owner_incarnation: 1,
              project_binding: nil,
              scope_ref: nil,
              signal_cursor: nil,
              recent_signal_hashes: [],
              lifecycle_status: :blocked,
              last_active_at: ~U[2026-04-10 10:00:00Z],
              active_plan: nil,
              active_authority_decision: nil,
              last_rejection: nil,
              boundary_ref: nil,
              outbox_entry_ids: [entry_id],
              external_refs: %{},
              extensions: %{}
            }),
          outbox_entries: %{entry_id => entry},
          extensions: %{}
        })
      )
  end

  defp dead_letter_entry(entry_id, dead_letter_reason) do
    ActionOutboxEntry.new!(%{
      schema_version: 1,
      entry_id: entry_id,
      causal_group_id: "group/#{entry_id}",
      action:
        LocalAction.new!(%{
          action_kind: "publish_projection",
          payload: %{"entry_id" => entry_id},
          extensions: %{}
        }),
      inserted_at: ~U[2026-04-10 10:00:00Z],
      replay_status: :dead_letter,
      durable_receipt_ref: nil,
      attempt_count: 3,
      max_attempts: 3,
      backoff_policy:
        BackoffPolicy.new!(%{
          strategy: :fixed,
          base_delay_ms: 100,
          max_delay_ms: 100,
          linear_step_ms: nil,
          multiplier: nil,
          jitter_mode: :none,
          jitter_window_ms: 0,
          extensions: %{}
        }),
      next_attempt_at: nil,
      last_error_code: "sink_unavailable",
      dead_letter_reason: dead_letter_reason,
      ordering_mode: :strict,
      staleness_mode: :stale_exempt,
      staleness_requirements: nil,
      extensions: %{}
    })
  end

  defp unique_name(prefix) do
    {:global, {__MODULE__, prefix, System.unique_integer([:positive])}}
  end
end
