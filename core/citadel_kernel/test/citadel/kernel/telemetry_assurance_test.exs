defmodule Citadel.Kernel.TelemetryAssuranceTest do
  use ExUnit.Case, async: false

  alias Citadel.ActionOutboxEntry
  alias Citadel.BackoffPolicy
  alias Citadel.KernelEpochUpdate
  alias Citadel.LocalAction
  alias Citadel.ObservabilityContract.Telemetry
  alias Citadel.PersistedSessionBlob
  alias Citadel.PersistedSessionEnvelope
  alias Citadel.Kernel.BoundaryLeaseTracker
  alias Citadel.Kernel.KernelSnapshot
  alias Citadel.Kernel.SessionDirectory
  alias Citadel.Kernel.SignalIngress
  alias Citadel.SignalIngressRebuildPolicy

  @initial_now ~U[2026-04-10 10:00:00Z]

  defmodule TelemetryForwarder do
    def handle_event(event, measurements, metadata, test_pid) do
      send(test_pid, {:telemetry, event, measurements, metadata})
    end
  end

  defmodule TestClock do
    def utc_now do
      Agent.get(__MODULE__, & &1)
    end

    def set!(datetime) do
      Agent.update(__MODULE__, fn _ -> datetime end)
    end
  end

  defmodule TestSignalSource do
    @behaviour Citadel.Ports.SignalSource

    @impl true
    def normalize_signal(observation), do: {:ok, observation}
  end

  setup do
    start_supervised!(%{
      id: TestClock,
      start: {Agent, :start_link, [fn -> @initial_now end, [name: TestClock]]}
    })

    :ok
  end

  test "kernel snapshot lag telemetry uses the canonical event name and measurements" do
    kernel_snapshot = unique_name(:kernel_snapshot)
    attach_telemetry(self(), [:kernel_snapshot_lag])

    start_supervised!({KernelSnapshot, name: kernel_snapshot, clock: TestClock})

    assert :ok =
             KernelSnapshot.publish_epoch_update(
               kernel_snapshot,
               KernelEpochUpdate.new!(%{
                 source_owner: "telemetry_assurance_test",
                 constituent: :policy_epoch,
                 epoch: 1,
                 updated_at: DateTime.add(TestClock.utc_now(), -250, :millisecond),
                 extensions: %{"policy_version" => "policy/v1"}
               })
             )

    wait_until(fn -> KernelSnapshot.current_snapshot(kernel_snapshot).snapshot_seq == 1 end)

    events = collect_telemetry_events()
    event_name = Telemetry.event_name(:kernel_snapshot_lag)

    {measurements, metadata} =
      fetch_event!(events, event_name, fn measurements, metadata ->
        measurements == %{backlog: 0, lag_ms: 250} and metadata == %{}
      end)

    assert_contract_shape(:kernel_snapshot_lag, measurements, metadata)
  end

  test "signal ingress rebuild telemetry proves backlog, batch, and high-priority readiness" do
    kernel_snapshot = unique_name(:kernel_snapshot)
    session_directory = unique_name(:session_directory)
    signal_ingress = unique_name(:signal_ingress)

    attach_telemetry(self(), [
      :signal_ingress_rebuild_backlog,
      :signal_ingress_rebuild_batch_latency,
      :signal_ingress_high_priority_ready_latency
    ])

    start_supervised!({KernelSnapshot, name: kernel_snapshot, clock: TestClock})

    start_supervised!(
      {SessionDirectory,
       name: session_directory, kernel_snapshot: kernel_snapshot, clock: TestClock}
    )

    assert :ok =
             SessionDirectory.register_active_session(session_directory, "sess-explicit",
               committed_signal_cursor: "cursor-1",
               priority_class: "explicit_resume"
             )

    assert :ok =
             SessionDirectory.register_active_session(session_directory, "sess-background",
               committed_signal_cursor: "cursor-2",
               priority_class: "background"
             )

    start_supervised!(
      {SignalIngress,
       name: signal_ingress,
       clock: TestClock,
       session_directory: session_directory,
       signal_source: TestSignalSource,
       rebuild_policy:
         SignalIngressRebuildPolicy.new!(%{
           max_sessions_per_batch: 1,
           batch_interval_ms: 1,
           high_priority_ready_slo_ms: 5_000,
           priority_order: [
             "explicit_resume",
             "live_request",
             "pending_replay_safe",
             "background"
           ],
           extensions: %{}
         })}
    )

    assert :ok = SignalIngress.rebuild_from_directory(signal_ingress)

    wait_until(fn ->
      snapshot = SignalIngress.snapshot(signal_ingress)
      map_size(snapshot.rebuild_queue) == 0 and map_size(snapshot.subscriptions) == 2
    end)

    events = collect_telemetry_events()
    backlog_event = Telemetry.event_name(:signal_ingress_rebuild_backlog)
    batch_event = Telemetry.event_name(:signal_ingress_rebuild_batch_latency)
    ready_event = Telemetry.event_name(:signal_ingress_high_priority_ready_latency)

    {backlog_measurements, backlog_metadata} =
      fetch_event!(events, backlog_event, fn measurements, metadata ->
        measurements == %{count: 1} and metadata == %{priority_class: "explicit_resume"}
      end)

    assert_contract_shape(
      :signal_ingress_rebuild_backlog,
      backlog_measurements,
      backlog_metadata
    )

    {batch_measurements, batch_metadata} =
      fetch_event!(events, batch_event, fn measurements, metadata ->
        is_integer(measurements.duration_ms) and measurements.duration_ms >= 0 and
          metadata == %{priority_class: "explicit_resume"}
      end)

    assert_contract_shape(
      :signal_ingress_rebuild_batch_latency,
      batch_measurements,
      batch_metadata
    )

    {ready_measurements, ready_metadata} =
      fetch_event!(events, ready_event, fn measurements, metadata ->
        measurements == %{duration_ms: 0} and metadata == %{}
      end)

    assert_contract_shape(
      :signal_ingress_high_priority_ready_latency,
      ready_measurements,
      ready_metadata
    )
  end

  test "boundary lease tracker circuit-open telemetry proves bridge family and scope class" do
    kernel_snapshot = unique_name(:kernel_snapshot)
    boundary_tracker = unique_name(:boundary_tracker)

    attach_telemetry(self(), [:bridge_circuit_open])

    start_supervised!({KernelSnapshot, name: kernel_snapshot, clock: TestClock})

    start_supervised!(
      {BoundaryLeaseTracker,
       name: boundary_tracker,
       clock: TestClock,
       kernel_snapshot: kernel_snapshot,
       classification_key_fun: fn _boundary_ref -> "resume-bootstrap" end}
    )

    assert :ok =
             BoundaryLeaseTracker.set_circuit_open(boundary_tracker, "resume-bootstrap", true)

    assert {:error, :circuit_open} =
             BoundaryLeaseTracker.classify_for_resume(boundary_tracker, "boundary-1")

    events = collect_telemetry_events()
    event_name = Telemetry.event_name(:bridge_circuit_open)

    {measurements, metadata} =
      fetch_event!(events, event_name, fn measurements, metadata ->
        measurements == %{count: 1} and
          metadata == %{
            bridge_family: :boundary,
            circuit_scope_class: :targeted_resume_bootstrap,
            boundary_ref: "boundary-1"
          }
      end)

    assert_contract_shape(:bridge_circuit_open, measurements, metadata)
  end

  test "session directory blocked-session and bulk-recovery telemetry use canonical fields" do
    kernel_snapshot = unique_name(:kernel_snapshot)
    session_directory = unique_name(:session_directory)
    session_id = "sess-blocked"
    entry_id = "entry-blocked"

    attach_telemetry(self(), [
      :blocked_session_count,
      :blocked_session_alert_count,
      :dead_letter_bulk_recovery
    ])

    start_supervised!({KernelSnapshot, name: kernel_snapshot, clock: TestClock})

    start_supervised!(
      {SessionDirectory,
       name: session_directory, kernel_snapshot: kernel_snapshot, clock: TestClock}
    )

    assert :ok =
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
                     last_active_at: TestClock.utc_now(),
                     active_plan: nil,
                     active_authority_decision: nil,
                     last_rejection: nil,
                     boundary_ref: nil,
                     outbox_entry_ids: [entry_id],
                     external_refs: %{},
                     extensions: %{}
                   }),
                 outbox_entries: %{entry_id => dead_letter_entry(entry_id)},
                 extensions: %{}
               })
             )

    assert {:ok, 1} =
             SessionDirectory.bulk_recover_dead_letters(
               session_directory,
               [dead_letter_reason: "projection_backend_down", ordering_mode: :strict],
               {:retry_with_override, "operator retry"}
             )

    events = collect_telemetry_events()
    blocked_event = Telemetry.event_name(:blocked_session_count)
    alert_event = Telemetry.event_name(:blocked_session_alert_count)
    bulk_recovery_event = Telemetry.event_name(:dead_letter_bulk_recovery)

    {blocked_measurements, blocked_metadata} =
      fetch_event!(events, blocked_event, fn measurements, metadata ->
        measurements == %{count: 1} and metadata == %{reason_family: "projection_backend_down"}
      end)

    assert_contract_shape(:blocked_session_count, blocked_measurements, blocked_metadata)

    {alert_measurements, alert_metadata} =
      fetch_event!(events, alert_event, fn measurements, metadata ->
        measurements == %{count: 1} and
          metadata == %{strict_dead_letter_family: "projection_backend_down"}
      end)

    assert_contract_shape(:blocked_session_alert_count, alert_measurements, alert_metadata)

    {bulk_measurements, bulk_metadata} =
      fetch_event!(events, bulk_recovery_event, fn measurements, metadata ->
        measurements == %{operation_count: 1, affected_entry_count: 1} and metadata == %{}
      end)

    assert_contract_shape(:dead_letter_bulk_recovery, bulk_measurements, bulk_metadata)
  end

  defp dead_letter_entry(entry_id) do
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
      inserted_at: @initial_now,
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
      dead_letter_reason: "projection_backend_down",
      ordering_mode: :strict,
      staleness_mode: :stale_exempt,
      staleness_requirements: nil,
      extensions: %{}
    })
  end

  defp attach_telemetry(test_pid, telemetry_names) do
    handler_id = "telemetry-assurance-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler_id,
      Enum.map(telemetry_names, &Telemetry.event_name/1),
      &TelemetryForwarder.handle_event/4,
      test_pid
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp collect_telemetry_events(timeout_ms \\ 100) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_collect_telemetry_events([], deadline)
  end

  defp do_collect_telemetry_events(events, deadline) do
    remaining_ms = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:telemetry, event, measurements, metadata} ->
        do_collect_telemetry_events([{event, measurements, metadata} | events], deadline)
    after
      remaining_ms ->
        Enum.reverse(events)
    end
  end

  defp fetch_event!(events, event_name, matcher) do
    Enum.find_value(events, fn
      {^event_name, measurements, metadata} ->
        if matcher.(measurements, metadata), do: {measurements, metadata}, else: false

      _other ->
        false
    end) ||
      flunk("expected telemetry event #{inspect(event_name)} in #{inspect(events)}")
  end

  defp assert_contract_shape(telemetry_name, measurements, metadata) do
    assert Enum.sort(Map.keys(measurements)) ==
             telemetry_name |> Telemetry.measurement_keys() |> Enum.sort()

    assert Enum.sort(Map.keys(metadata)) ==
             telemetry_name |> Telemetry.metadata_keys() |> Enum.sort()
  end

  defp unique_name(prefix) do
    {:global, {__MODULE__, prefix, System.unique_integer([:positive])}}
  end

  defp wait_until(fun, attempts \\ 40)

  defp wait_until(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      wait_until(fun, attempts - 1)
    end
  end

  defp wait_until(_fun, 0) do
    flunk("condition did not become true in time")
  end
end
