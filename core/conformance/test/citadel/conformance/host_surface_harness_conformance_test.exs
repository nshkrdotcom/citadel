defmodule Citadel.Conformance.HostSurfaceHarnessConformanceTest do
  use ExUnit.Case, async: false

  alias Citadel.Apps.HostSurfaceHarness
  alias Citadel.PersistedSessionBlob
  alias Citadel.ProjectionBridge
  alias Citadel.Kernel.BoundaryLeaseTracker
  alias Citadel.Kernel.KernelSnapshot
  alias Citadel.Kernel.ServiceCatalog
  alias Citadel.Kernel.SessionDirectory
  alias Citadel.Kernel.SessionServer
  alias Citadel.Kernel.SignalIngress
  alias Citadel.RuntimeObservation
  alias Citadel.SignalBridge

  defmodule Resolver do
    def resolve_intent(%{"mode" => "resolved"}) do
      {:ok,
       HostSurfaceHarness.valid_direct_envelope(%{
         intent_envelope_id: "intent/conformance/resolved"
       })}
    end

    def resolve_intent(_raw_input), do: {:error, :unsupported_shape}
  end

  defmodule ProjectionDownstream do
    def publish_review_projection(projection, metadata) do
      send(Process.get(:conformance_test_pid), {:review_projection, projection, metadata})
      {:ok, "review:#{metadata.entry_id}"}
    end

    def publish_derived_state_attachment(attachment, metadata) do
      send(Process.get(:conformance_test_pid), {:derived_state_attachment, attachment, metadata})
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
         extensions: %{}
       })}
    end
  end

  defmodule TestSignalSource do
    @behaviour Citadel.Ports.SignalSource

    @impl true
    def normalize_signal(observation), do: {:ok, observation}
  end

  setup do
    Process.put(:conformance_test_pid, self())

    kernel_snapshot = unique_name(:kernel_snapshot)
    session_directory = unique_name(:session_directory)
    service_catalog = unique_name(:service_catalog)
    boundary_tracker = unique_name(:boundary_tracker)
    signal_ingress = unique_name(:signal_ingress)
    invocation_supervisor = unique_name(:invocation_supervisor)
    projection_supervisor = unique_name(:projection_supervisor)
    local_supervisor = unique_name(:local_supervisor)

    start_supervised!({KernelSnapshot, name: kernel_snapshot})

    start_supervised!(
      {SessionDirectory, name: session_directory, kernel_snapshot: kernel_snapshot}
    )

    start_supervised!({ServiceCatalog, name: service_catalog, kernel_snapshot: kernel_snapshot})

    start_supervised!(
      {BoundaryLeaseTracker, name: boundary_tracker, kernel_snapshot: kernel_snapshot}
    )

    start_supervised!({Task.Supervisor, name: invocation_supervisor, max_children: 4})
    start_supervised!({Task.Supervisor, name: projection_supervisor, max_children: 4})
    start_supervised!({Task.Supervisor, name: local_supervisor, max_children: 4})

    start_supervised!(
      {SignalIngress,
       name: signal_ingress,
       session_directory: session_directory,
       signal_source: TestSignalSource,
       auto_rebuild?: false}
    )

    {:ok,
     kernel_snapshot: kernel_snapshot,
     session_directory: session_directory,
     service_catalog: service_catalog,
     boundary_tracker: boundary_tracker,
     signal_ingress: signal_ingress,
     invocation_supervisor: invocation_supervisor,
     projection_supervisor: projection_supervisor,
     local_supervisor: local_supervisor}
  end

  test "composes multi-session, multi-ingress, and rejection publication above Citadel without a second core",
       setup do
    signal_bridge = SignalBridge.new!(adapter: SignalAdapter)

    harness =
      HostSurfaceHarness.new!(
        session_directory: setup.session_directory,
        signal_bridge: signal_bridge,
        projection_bridge: ProjectionBridge.new!(downstream: ProjectionDownstream),
        intent_resolver: Resolver,
        policy_packs: [policy_pack()]
      )

    assert {:accepted, accepted_a, _harness} =
             HostSurfaceHarness.submit_envelope(
               harness,
               HostSurfaceHarness.valid_direct_envelope(%{
                 intent_envelope_id: "intent/conformance/a"
               }),
               request_context("req-a", "sess-a")
             )

    assert {:accepted, accepted_b, _harness} =
             HostSurfaceHarness.submit_resolved_input(
               harness,
               %{"mode" => "resolved"},
               request_context("req-b", "sess-b")
             )

    assert accepted_a.ingress_path == :direct_intent_envelope
    assert accepted_b.ingress_path == :resolved_input

    {:ok, session_a} =
      SessionServer.start_link(
        name: unique_name(:session_a),
        session_id: "sess-a",
        session_directory: setup.session_directory,
        kernel_snapshot: setup.kernel_snapshot,
        boundary_lease_tracker: setup.boundary_tracker,
        service_catalog: setup.service_catalog,
        signal_ingress: setup.signal_ingress,
        invocation_supervisor: setup.invocation_supervisor,
        projection_supervisor: setup.projection_supervisor,
        local_supervisor: setup.local_supervisor,
        request_id: "req-a",
        trace_id: "trace/req-a",
        tenant_id: "tenant-1"
      )

    {:ok, session_b} =
      SessionServer.start_link(
        name: unique_name(:session_b),
        session_id: "sess-b",
        session_directory: setup.session_directory,
        kernel_snapshot: setup.kernel_snapshot,
        boundary_lease_tracker: setup.boundary_tracker,
        service_catalog: setup.service_catalog,
        signal_ingress: setup.signal_ingress,
        invocation_supervisor: setup.invocation_supervisor,
        projection_supervisor: setup.projection_supervisor,
        local_supervisor: setup.local_supervisor,
        request_id: "req-b",
        trace_id: "trace/req-b",
        tenant_id: "tenant-1"
      )

    harness = %{
      harness
      | lookup_session: fn
          "sess-a" -> {:ok, session_a}
          "sess-b" -> {:ok, session_b}
          _session_id -> {:error, :not_found}
        end
    }

    assert {:ok, %{signal_id: "sig-a"}, _harness} =
             HostSurfaceHarness.deliver_signal(
               harness,
               "sess-a",
               %{session_id: "sess-a", signal_id: "sig-a", payload: %{"kind" => "operator_event"}}
             )

    assert {:ok, %{signal_id: "sig-b"}, _harness} =
             HostSurfaceHarness.deliver_signal(
               harness,
               "sess-b",
               %{session_id: "sess-b", signal_id: "sig-b", payload: %{"kind" => "webhook"}}
             )

    Process.sleep(25)

    assert "sig-a" in SessionServer.snapshot(session_a).recent_signal_hashes
    assert "sig-b" in SessionServer.snapshot(session_b).recent_signal_hashes

    assert {:rejected, review_result, harness} =
             HostSurfaceHarness.submit_envelope(
               harness,
               HostSurfaceHarness.unplannable_direct_envelope(%{
                 intent_envelope_id: "intent/conformance/review"
               }),
               request_context("req-review", "sess-review"),
               rejection: %{
                 reason_code: "policy_denied",
                 summary: "policy denied the request",
                 causes: [:runtime_state, :policy_denial]
               }
             )

    assert review_result.rejection.publication_requirement == :review_projection
    assert_receive {:review_projection, projection, %{entry_id: review_entry_id}}

    assert projection.packet_ref ==
             "citadel://decision_rejection/#{review_result.rejection.rejection_id}"

    assert review_entry_id == "publish/#{review_result.rejection.rejection_id}"

    assert {:rejected, derived_result, _harness} =
             HostSurfaceHarness.submit_envelope(
               harness,
               HostSurfaceHarness.unplannable_direct_envelope(%{
                 intent_envelope_id: "intent/conformance/derived"
               }),
               request_context("req-derived", "sess-derived"),
               rejection: %{
                 reason_code: "planning_failed",
                 summary: "the request is valid but not plannable now",
                 causes: [:planning]
               }
             )

    assert derived_result.rejection.publication_requirement == :derived_state_attachment
    assert_receive {:derived_state_attachment, attachment, %{entry_id: derived_entry_id}}
    assert attachment.metadata["policy_pack_id"] == "default"
    assert derived_entry_id == "publish/#{derived_result.rejection.rejection_id}"

    assert %PersistedSessionBlob{} =
             HostSurfaceHarness.inspect_session(harness, "sess-review").raw_blob
  end

  test "keeps live-owner acceptance on the public host surface without rotating session ownership",
       setup do
    signal_bridge = SignalBridge.new!(adapter: SignalAdapter)

    {:ok, session_server} =
      SessionServer.start_link(
        name: unique_name(:live_owner_session),
        session_id: "sess-live-owner",
        session_directory: setup.session_directory,
        kernel_snapshot: setup.kernel_snapshot,
        boundary_lease_tracker: setup.boundary_tracker,
        service_catalog: setup.service_catalog,
        signal_ingress: setup.signal_ingress,
        invocation_supervisor: setup.invocation_supervisor,
        projection_supervisor: setup.projection_supervisor,
        local_supervisor: setup.local_supervisor,
        request_id: "req-live-owner",
        trace_id: "trace/req-live-owner",
        tenant_id: "tenant-1"
      )

    harness =
      HostSurfaceHarness.new!(
        session_directory: setup.session_directory,
        signal_bridge: signal_bridge,
        policy_packs: [policy_pack()],
        lookup_session: fn
          "sess-live-owner" -> {:ok, session_server}
          _session_id -> {:error, :not_found}
        end
      )

    assert {:accepted, accepted, _harness} =
             HostSurfaceHarness.submit_envelope(
               harness,
               HostSurfaceHarness.valid_direct_envelope(%{
                 intent_envelope_id: "intent/conformance/live-owner"
               }),
               request_context("req-live-owner", "sess-live-owner")
             )

    assert accepted.lifecycle_event == :live_owner

    assert {:ok, session_state} =
             SessionServer.commit_transition(session_server, %{
               external_refs: %{"conformance" => "ok"}
             })

    assert session_state.owner_incarnation == 1
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

  defp unique_name(prefix) do
    {:global, {__MODULE__, prefix, System.unique_integer([:positive])}}
  end
end
