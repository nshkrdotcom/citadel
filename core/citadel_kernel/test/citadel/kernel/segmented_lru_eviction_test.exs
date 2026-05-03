defmodule Citadel.Kernel.SegmentedLruEvictionTest do
  use ExUnit.Case, async: false

  alias Citadel.BoundaryLeaseView
  alias Citadel.Kernel.BoundaryLeaseTracker
  alias Citadel.Kernel.KernelSnapshot
  alias Citadel.Kernel.SessionDirectory
  alias Citadel.Kernel.SignalIngress
  alias Citadel.RuntimeObservation
  alias Jido.Integration.V2.SubjectRef

  defmodule TestSignalSource do
    @behaviour Citadel.Ports.SignalSource

    @impl true
    def normalize_signal(%RuntimeObservation{} = observation), do: {:ok, observation}
  end

  defmodule BlockingConsumer do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts), do: {:ok, %{test_pid: Keyword.fetch!(opts, :test_pid)}}

    @impl true
    def handle_call({:record_runtime_observation, observation}, _from, state) do
      send(state.test_pid, {:consumer_blocked, observation.signal_id})

      receive do
        {:release_consumer, signal_id} when signal_id == observation.signal_id ->
          {:reply, :ok, state}
      after
        2_000 ->
          {:reply, {:error, :timeout}, state}
      end
    end
  end

  defmodule RecordingConsumer do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts), do: {:ok, %{test_pid: Keyword.fetch!(opts, :test_pid)}}

    @impl true
    def handle_call({:record_runtime_observation, observation}, _from, state) do
      send(state.test_pid, {:consumer_recorded, observation.signal_id})
      {:reply, :ok, state}
    end
  end

  test "signal ingress sweeps expired idle segments without removing active partition work" do
    signal_ingress =
      start_signal_ingress(
        eviction_policy: [
          sweep_interval_ms: 0,
          max_evictions_per_sweep: 20,
          subscription_ttl_ms: 0,
          consumer_ttl_ms: 0,
          partition_state_ttl_ms: 0
        ]
      )

    dead_consumer = start_supervised!({RecordingConsumer, test_pid: self()})
    assert :ok = SignalIngress.register_subscription(signal_ingress, "sess-expired")
    assert :ok = SignalIngress.register_consumer(signal_ingress, "sess-expired", dead_consumer)

    ref = Process.monitor(dead_consumer)
    Process.exit(dead_consumer, :kill)
    assert_receive {:DOWN, ^ref, :process, ^dead_consumer, :killed}, 500

    assert {:ok, acceptance} =
             SignalIngress.deliver_observation(
               signal_ingress,
               observation("sess-expired", "sig-expired", subject_id: "subject-expired")
             )

    wait_until(fn ->
      snapshot = SignalIngress.snapshot(signal_ingress)
      Map.get(snapshot.partition_queue_depths, acceptance.partition_ref, 0) == 0
    end)

    assert %{consumers: 1, subscriptions: 1, partitions: 1} =
             SignalIngress.sweep_expired(signal_ingress)

    snapshot = SignalIngress.snapshot(signal_ingress)
    refute Map.has_key?(snapshot.subscriptions, "sess-expired")
    refute Map.has_key?(snapshot.consumers, "sess-expired")
    refute Map.has_key?(snapshot.partition_workers, acceptance.partition_ref)

    capped_ingress =
      start_signal_ingress(
        admission_policy:
          Keyword.merge(generous_admission_policy(), max_in_flight_per_tenant_scope: 10),
        eviction_policy: [
          sweep_interval_ms: 0,
          max_evictions_per_sweep: 20,
          partition_state_ttl_ms: 60_000,
          max_partitions_total: 1
        ]
      )

    blocking_consumer = start_supervised!({BlockingConsumer, test_pid: self()})
    assert :ok = SignalIngress.register_subscription(capped_ingress, "sess-blocked")

    assert :ok =
             SignalIngress.register_consumer(capped_ingress, "sess-blocked", blocking_consumer)

    assert {:ok, held_acceptance} =
             SignalIngress.deliver_observation(
               capped_ingress,
               observation("sess-blocked", "sig-held", subject_id: "subject-held")
             )

    assert_receive {:consumer_blocked, "sig-held"}, 500

    assert {:error, rejection} =
             SignalIngress.deliver_observation(
               capped_ingress,
               observation("sess-open", "sig-open", subject_id: "subject-open")
             )

    assert rejection.reason == :partition_capacity_exhausted
    assert rejection.queue_depth_before == 0
    assert rejection.queue_depth_after == 0

    capped_snapshot = SignalIngress.snapshot(capped_ingress)
    assert Map.has_key?(capped_snapshot.partition_workers, held_acceptance.partition_ref)

    send(blocking_consumer, {:release_consumer, "sig-held"})
  end

  test "signal ingress rejects rebuild queue cap pressure before merging protected work" do
    kernel_snapshot = unique_name(:kernel_snapshot)
    session_directory = unique_name(:session_directory)
    signal_ingress = unique_name(:signal_ingress)

    start_supervised!({KernelSnapshot, name: kernel_snapshot})

    start_supervised!(
      {SessionDirectory, name: session_directory, kernel_snapshot: kernel_snapshot}
    )

    assert :ok =
             SessionDirectory.register_active_session(session_directory, "sess-one",
               committed_signal_cursor: "cursor-1"
             )

    assert :ok =
             SessionDirectory.register_active_session(session_directory, "sess-two",
               committed_signal_cursor: "cursor-2"
             )

    start_supervised!(
      {SignalIngress,
       name: signal_ingress,
       session_directory: session_directory,
       signal_source: TestSignalSource,
       eviction_policy: [
         sweep_interval_ms: 0,
         rebuild_queue_ttl_ms: 60_000,
         max_rebuild_queue_total: 1
       ]}
    )

    assert {:error, rejection} = SignalIngress.rebuild_from_directory(signal_ingress)
    assert rejection.reason == :rebuild_queue_capacity_exhausted
    assert rejection.resource_exhaustion? == true
    assert SignalIngress.snapshot(signal_ingress).rebuild_queue == %{}
  end

  test "boundary lease tracker evicts expired lease and rejects unexpired cap pressure" do
    kernel_snapshot = unique_name(:kernel_snapshot)
    boundary_tracker = unique_name(:boundary_tracker)
    now = DateTime.utc_now()

    start_supervised!({KernelSnapshot, name: kernel_snapshot})

    start_supervised!(
      {BoundaryLeaseTracker,
       name: boundary_tracker,
       kernel_snapshot: kernel_snapshot,
       eviction_policy: [
         sweep_interval_ms: 0,
         max_evictions_per_sweep: 10,
         lease_ttl_ms: 60_000,
         circuit_open_ttl_ms: 0,
         max_leases_total: 1,
         max_circuit_open_keys_total: 1
       ]}
    )

    assert {:ok, _epoch} =
             BoundaryLeaseTracker.record_boundary_view(
               boundary_tracker,
               lease_view("expired-boundary", DateTime.add(now, -1, :second))
             )

    assert %{leases: 1} = BoundaryLeaseTracker.sweep_expired(boundary_tracker)
    assert BoundaryLeaseTracker.snapshot(boundary_tracker).leases == %{}

    assert {:ok, _epoch} =
             BoundaryLeaseTracker.record_boundary_view(
               boundary_tracker,
               lease_view("live-boundary", DateTime.add(now, 60, :second))
             )

    assert {:error, rejection} =
             BoundaryLeaseTracker.record_boundary_view(
               boundary_tracker,
               lease_view("second-live-boundary", DateTime.add(now, 60, :second))
             )

    assert rejection.reason == :lease_capacity_exhausted
    assert Map.has_key?(BoundaryLeaseTracker.snapshot(boundary_tracker).leases, "live-boundary")

    assert :ok = BoundaryLeaseTracker.set_circuit_open(boundary_tracker, "old-circuit", true)
    assert %{circuit_open_keys: 1} = BoundaryLeaseTracker.sweep_expired(boundary_tracker)

    refute MapSet.member?(
             BoundaryLeaseTracker.snapshot(boundary_tracker).circuit_open_keys,
             "old-circuit"
           )
  end

  test "boundary lease tracker rejects new bootstrap when in-flight cap protects active waiters" do
    kernel_snapshot = unique_name(:kernel_snapshot)
    boundary_tracker = unique_name(:boundary_tracker)

    start_supervised!({KernelSnapshot, name: kernel_snapshot})

    start_supervised!(
      {BoundaryLeaseTracker,
       name: boundary_tracker,
       kernel_snapshot: kernel_snapshot,
       eviction_policy: [
         sweep_interval_ms: 0,
         inflight_bootstrap_ttl_ms: 60_000,
         max_inflight_bootstraps_total: 1
       ],
       bootstrap_fun: fn boundary_ref ->
         Process.sleep(100)
         {:ok, lease_view(boundary_ref, nil)}
       end}
    )

    task =
      Task.async(fn ->
        BoundaryLeaseTracker.classify_for_resume(boundary_tracker, "boundary-a")
      end)

    wait_until(fn ->
      map_size(BoundaryLeaseTracker.snapshot(boundary_tracker).inflight) == 1
    end)

    assert {:error, :bootstrap_capacity_exhausted} =
             BoundaryLeaseTracker.classify_for_resume(boundary_tracker, "boundary-b")

    assert {:ok, %BoundaryLeaseView{boundary_ref: "boundary-a"}} = Task.await(task, 1_000)
  end

  test "session directory sweeps expired active-session metadata and rejects protected caps" do
    kernel_snapshot = unique_name(:kernel_snapshot)
    session_directory = unique_name(:session_directory)

    start_supervised!({KernelSnapshot, name: kernel_snapshot})

    start_supervised!(
      {SessionDirectory,
       name: session_directory,
       kernel_snapshot: kernel_snapshot,
       eviction_policy: [
         sweep_interval_ms: 0,
         active_session_ttl_ms: 0,
         max_active_sessions_total: 10,
         max_active_sessions_per_tenant: 10
       ]}
    )

    assert :ok =
             SessionDirectory.register_active_session(session_directory, "sess-expired",
               tenant_id: "tenant-a",
               authority_scope: "authority-a"
             )

    assert %{active_sessions: 1} = SessionDirectory.sweep_expired(session_directory)
    assert SessionDirectory.list_active_session_cursors(session_directory) == []

    capped_directory = unique_name(:session_directory)

    start_supervised!(
      {SessionDirectory,
       name: capped_directory,
       kernel_snapshot: kernel_snapshot,
       eviction_policy: [
         sweep_interval_ms: 0,
         active_session_ttl_ms: 60_000,
         max_active_sessions_total: 10,
         max_active_sessions_per_tenant: 1
       ]},
      id: capped_directory
    )

    assert :ok =
             SessionDirectory.register_active_session(capped_directory, "sess-one",
               tenant_id: "tenant-a",
               authority_scope: "authority-a"
             )

    assert {:error, rejection} =
             SessionDirectory.register_active_session(capped_directory, "sess-two",
               tenant_id: "tenant-a",
               authority_scope: "authority-a"
             )

    assert rejection.reason == :active_session_tenant_capacity_exhausted
    assert length(SessionDirectory.list_active_session_cursors(capped_directory)) == 1
  end

  defp start_signal_ingress(opts) do
    name = unique_name(:signal_ingress)

    start_supervised!(
      {SignalIngress,
       Keyword.merge(
         [
           name: name,
           signal_source: TestSignalSource,
           admission_policy: generous_admission_policy()
         ],
         opts
       )},
      id: name
    )

    name
  end

  defp generous_admission_policy do
    [
      bucket_capacity: 16,
      refill_rate_per_second: 0,
      max_queue_depth_per_partition: 16,
      max_in_flight_per_tenant_scope: 16,
      retry_after_ms: 100,
      delivery_order_scope: :partition_fifo
    ]
  end

  defp observation(session_id, signal_id, opts) do
    subject_id = Keyword.fetch!(opts, :subject_id)

    RuntimeObservation.new!(%{
      observation_id: "obs/#{signal_id}",
      request_id: "req/#{signal_id}",
      session_id: session_id,
      signal_id: signal_id,
      signal_cursor: "cursor/#{signal_id}",
      runtime_ref_id: "runtime/#{session_id}",
      event_kind: "host_signal",
      event_at: DateTime.utc_now(),
      status: "ok",
      output: %{},
      artifacts: [],
      payload: %{"status" => "ok"},
      subject_ref: SubjectRef.new!(%{kind: :run, id: subject_id, metadata: %{}}),
      evidence_refs: [],
      governance_refs: [],
      extensions: %{
        "tenant_id" => "tenant-1",
        "authority_scope" => "authority-1",
        "trace_id" => "trace/#{signal_id}",
        "causation_id" => "cause/#{signal_id}",
        "canonical_idempotency_key" => "idem:v1:#{signal_id}"
      }
    })
  end

  defp lease_view(boundary_ref, expires_at) do
    BoundaryLeaseView.new!(%{
      boundary_ref: boundary_ref,
      last_heartbeat_at: nil,
      expires_at: expires_at,
      staleness_status: if(is_nil(expires_at), do: :missing, else: :fresh),
      lease_epoch: 1,
      extensions: %{}
    })
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

  defp wait_until(_fun, 0), do: flunk("condition did not become true in time")

  defp unique_name(prefix),
    do: {:global, {__MODULE__, prefix, System.unique_integer([:positive, :monotonic])}}
end
