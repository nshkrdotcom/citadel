Code.require_file(Path.expand("../../../../../dev/docker/toxiproxy/test_support.exs", __DIR__))

defmodule Citadel.Kernel.InfrastructureFaultInjectionTest do
  use ExUnit.Case, async: false

  alias Citadel.ActionOutboxEntry
  alias Citadel.BackoffPolicy
  alias Citadel.BridgeCircuit
  alias Citadel.BridgeCircuitPolicy
  alias Citadel.LocalAction
  alias Citadel.ObservabilityContract.Telemetry
  alias Citadel.PersistedSessionBlob
  alias Citadel.PersistedSessionEnvelope
  alias Citadel.Kernel.BoundaryLeaseTracker
  alias Citadel.Kernel.KernelSnapshot
  alias Citadel.Kernel.ServiceCatalog
  alias Citadel.Kernel.SessionDirectory
  alias Citadel.Kernel.SessionServer
  alias Citadel.Kernel.SignalIngress
  alias Citadel.ScopeRef
  alias Citadel.StalenessRequirements
  alias Citadel.TestSupport.ToxiproxyHarness

  @proxy_name "citadel_nginx"
  @timeout_key {__MODULE__, :proxy_timeout_ms}
  @clock_agent __MODULE__.TestClock

  defmodule TestClock do
    def utc_now do
      Agent.get(Citadel.Kernel.InfrastructureFaultInjectionTest.TestClock, & &1)
    end

    def set!(datetime) do
      Agent.update(Citadel.Kernel.InfrastructureFaultInjectionTest.TestClock, fn _ ->
        datetime
      end)
    end

    def advance!(amount, unit) do
      Agent.update(Citadel.Kernel.InfrastructureFaultInjectionTest.TestClock, fn datetime ->
        DateTime.add(datetime, amount, unit)
      end)
    end
  end

  defmodule TestSignalSource do
    @behaviour Citadel.Ports.SignalSource

    @impl true
    def normalize_signal(observation), do: {:ok, observation}
  end

  defmodule ToxiproxyDownstream do
    alias Citadel.TestSupport.ToxiproxyHarness

    def submit_execution_intent(envelope) do
      timeout =
        :persistent_term.get({Citadel.Kernel.InfrastructureFaultInjectionTest, :proxy_timeout_ms})

      ToxiproxyHarness.request_url(
        :get,
        ToxiproxyHarness.proxy_url("/"),
        timeout: timeout,
        connect_timeout: timeout
      )
      |> ToxiproxyHarness.normalize_http_result("receipt:#{envelope.entry_id}")
    end
  end

  defmodule SharedInvocationCircuit do
    def start_link(opts) do
      Agent.start_link(fn ->
        %{
          circuit: BridgeCircuit.new!(policy: Keyword.fetch!(opts, :circuit_policy)),
          scope_key: Keyword.get(opts, :scope_key, "http:toxiproxy")
        }
      end)
    end

    def submit(server, entry) do
      Agent.get_and_update(server, fn %{circuit: circuit, scope_key: scope_key} = state ->
        case BridgeCircuit.allow(circuit, scope_key) do
          {:ok, allowed_circuit} ->
            case ToxiproxyDownstream.submit_execution_intent(%{entry_id: entry.entry_id}) do
              {:ok, durable_receipt_ref} ->
                {{:ok, durable_receipt_ref},
                 %{state | circuit: BridgeCircuit.record_success(allowed_circuit, scope_key)}}

              {:error, reason} ->
                {{:error, reason},
                 %{state | circuit: BridgeCircuit.record_failure(allowed_circuit, scope_key)}}
            end

          {{:error, :circuit_open}, open_circuit} ->
            {{:error, :circuit_open}, %{state | circuit: open_circuit}}
        end
      end)
    end
  end

  setup do
    initial_now = ~U[2026-04-10 10:00:00Z]

    if wave12_enabled?() do
      case ToxiproxyHarness.availability_result!("Citadel.Kernel Wave 12 fault injection") do
        :ok -> :ok
        {:skip, _reason} -> :ok
      end

      ToxiproxyHarness.ensure_proxy!()
      :persistent_term.put(@timeout_key, 200)
    end

    start_supervised!(%{
      id: @clock_agent,
      start: {Agent, :start_link, [fn -> initial_now end, [name: @clock_agent]]}
    })

    on_exit(fn ->
      if wave12_enabled?() do
        ToxiproxyHarness.ensure_proxy!()
      end

      :persistent_term.erase(@timeout_key)
      detach_telemetry_handler("wave-12-invocation-backlog")
    end)

    {:ok, initial_now: initial_now}
  end

  test "outbox retries preserve payload, schedule deterministic backoff, and dead-letter when the circuit stays hostile",
       %{initial_now: initial_now} do
    run_wave12(fn ->
      env = start_runtime_env()

      ToxiproxyHarness.add_toxic!(@proxy_name, "latency", "latency", %{"latency" => 800})

      holder =
        start_supervised!(%{
          id: unique_name(:shared_invocation_circuit),
          start:
            {SharedInvocationCircuit, :start_link,
             [
               [
                 circuit_policy:
                   BridgeCircuitPolicy.new!(%{
                     failure_threshold: 1,
                     window_ms: 5_000,
                     cooldown_ms: 5_000,
                     half_open_max_inflight: 1,
                     scope_key_mode: "downstream_scope",
                     extensions: %{}
                   })
               ]
             ]}
        })

      session_id = "sess-fault-retry"
      entry = outbox_entry("entry-fault-retry", max_attempts: 2, base_delay_ms: 250)

      seed_session_blob(env.session_directory, session_id, [entry])

      start_supervised!(
        Supervisor.child_spec(
          {SessionServer,
           name: env.session_server_name,
           session_id: session_id,
           clock: TestClock,
           session_directory: env.session_directory,
           kernel_snapshot: env.kernel_snapshot,
           boundary_lease_tracker: env.boundary_tracker,
           service_catalog: env.service_catalog,
           signal_ingress: env.signal_ingress,
           invocation_supervisor: env.invocation_supervisor,
           projection_supervisor: env.projection_supervisor,
           local_supervisor: env.local_supervisor,
           invocation_handler: fn _payload, attempt_entry ->
             SharedInvocationCircuit.submit(holder, attempt_entry)
           end},
          id: unique_name(:session_server_child)
        )
      )

      wait_until(fn ->
        current_entry =
          env.session_server_name
          |> SessionServer.snapshot()
          |> Map.fetch!(:outbox)
          |> Map.fetch!(:entries_by_id)
          |> Map.fetch!(entry.entry_id)

        current_entry.attempt_count == 1 and
          current_entry.replay_status == :pending and
          current_entry.last_error_code == "timeout"
      end)

      after_first_failure =
        env.session_server_name
        |> SessionServer.snapshot()
        |> Map.fetch!(:outbox)
        |> Map.fetch!(:entries_by_id)
        |> Map.fetch!(entry.entry_id)

      expected_delay_ms =
        BackoffPolicy.compute_delay_ms!(
          after_first_failure.backoff_policy,
          after_first_failure.entry_id,
          after_first_failure.attempt_count
        )

      assert after_first_failure.action.payload == entry.action.payload
      assert after_first_failure.attempt_count == 1

      assert after_first_failure.next_attempt_at ==
               DateTime.add(initial_now, expected_delay_ms, :millisecond)

      TestClock.set!(DateTime.add(after_first_failure.next_attempt_at, 1, :millisecond))
      assert :ok = SessionServer.replay_pending(env.session_server_name)

      wait_until(fn ->
        session_state = SessionServer.snapshot(env.session_server_name)
        current_entry = Map.fetch!(session_state.outbox.entries_by_id, entry.entry_id)

        current_entry.replay_status == :dead_letter and
          session_state.lifecycle_status == :blocked and
          current_entry.dead_letter_reason == "circuit_open"
      end)

      final_session_state = SessionServer.snapshot(env.session_server_name)
      final_entry = Map.fetch!(final_session_state.outbox.entries_by_id, entry.entry_id)

      assert final_entry.action.payload == entry.action.payload
      assert final_entry.attempt_count == 2
      assert final_entry.last_error_code == "circuit_open"
      assert final_entry.dead_letter_reason == "circuit_open"
      assert is_nil(final_entry.next_attempt_at)
      assert final_session_state.lifecycle_status == :blocked
      assert final_session_state.extensions["blocked_failure"]["entry_id"] == entry.entry_id

      assert {:ok, persisted_blob} =
               SessionDirectory.fetch_persisted_blob(env.session_directory, session_id)

      persisted_entry = Map.fetch!(persisted_blob.outbox_entries, entry.entry_id)
      assert persisted_entry.action.payload == entry.action.payload
      assert persisted_entry.attempt_count == 2
      assert persisted_entry.dead_letter_reason == "circuit_open"
    end)
  end

  test "an open invocation bridge circuit fast-fails queued sessions before the bounded worker pool saturates" do
    run_wave12(fn ->
      env = start_runtime_env(max_children: 1)
      attach_invocation_backlog_probe("wave-12-invocation-backlog", self())

      ToxiproxyHarness.add_toxic!(@proxy_name, "latency", "latency", %{"latency" => 800})

      holder =
        start_supervised!(%{
          id: unique_name(:shared_invocation_circuit),
          start:
            {SharedInvocationCircuit, :start_link,
             [
               [
                 circuit_policy:
                   BridgeCircuitPolicy.new!(%{
                     failure_threshold: 1,
                     window_ms: 5_000,
                     cooldown_ms: 5_000,
                     half_open_max_inflight: 1,
                     scope_key_mode: "downstream_scope",
                     extensions: %{}
                   })
               ]
             ]}
        })

      assert {:error, :timeout} =
               SharedInvocationCircuit.submit(
                 holder,
                 outbox_entry("prime-circuit", max_attempts: 1)
               )

      ToxiproxyHarness.ensure_proxy!()

      session_ids = ["sess-fast-fail-a", "sess-fast-fail-b", "sess-fast-fail-c"]

      Enum.with_index(session_ids, 1)
      |> Enum.each(fn {session_id, index} ->
        entry = outbox_entry("entry-fast-fail-#{index}", max_attempts: 1)
        seed_session_blob(env.session_directory, session_id, [entry])

        start_supervised!(
          Supervisor.child_spec(
            {SessionServer,
             name: unique_name(:session_server),
             session_id: session_id,
             clock: TestClock,
             session_directory: env.session_directory,
             kernel_snapshot: env.kernel_snapshot,
             boundary_lease_tracker: env.boundary_tracker,
             service_catalog: env.service_catalog,
             signal_ingress: env.signal_ingress,
             invocation_supervisor: env.invocation_supervisor,
             projection_supervisor: env.projection_supervisor,
             local_supervisor: env.local_supervisor,
             invocation_handler: fn _payload, attempt_entry ->
               SharedInvocationCircuit.submit(holder, attempt_entry)
             end},
            id: unique_name(:session_server_child)
          )
        )
      end)

      wait_until(fn ->
        Enum.all?(session_ids, fn session_id ->
          case SessionDirectory.fetch_persisted_blob(env.session_directory, session_id) do
            {:ok, persisted_blob} ->
              persisted_blob.outbox_entries
              |> Map.values()
              |> Enum.all?(fn persisted_entry ->
                persisted_entry.replay_status == :dead_letter and
                  persisted_entry.dead_letter_reason == "circuit_open"
              end)

            {:error, _reason} ->
              false
          end
        end)
      end)

      refute_receive {:invocation_dispatch_backlog, _measurements, _metadata}, 200
    end)
  end

  defp start_runtime_env(opts \\ []) do
    kernel_snapshot = unique_name(:kernel_snapshot)
    session_directory = unique_name(:session_directory)
    service_catalog = unique_name(:service_catalog)
    boundary_tracker = unique_name(:boundary_tracker)
    signal_ingress = unique_name(:signal_ingress)
    invocation_supervisor = unique_name(:invocation_supervisor)
    projection_supervisor = unique_name(:projection_supervisor)
    local_supervisor = unique_name(:local_supervisor)

    start_supervised!(
      {KernelSnapshot, name: kernel_snapshot, policy_version: "v1", policy_epoch: 1}
    )

    start_supervised!(
      {SessionDirectory, name: session_directory, kernel_snapshot: kernel_snapshot}
    )

    start_supervised!({ServiceCatalog, name: service_catalog, kernel_snapshot: kernel_snapshot})

    start_supervised!(
      {BoundaryLeaseTracker, name: boundary_tracker, kernel_snapshot: kernel_snapshot}
    )

    start_supervised!(
      {Task.Supervisor,
       name: invocation_supervisor, max_children: Keyword.get(opts, :max_children, 4)}
    )

    start_supervised!({Task.Supervisor, name: projection_supervisor, max_children: 4})
    start_supervised!({Task.Supervisor, name: local_supervisor, max_children: 4})

    start_supervised!(
      {SignalIngress,
       name: signal_ingress, session_directory: session_directory, signal_source: TestSignalSource}
    )

    %{
      kernel_snapshot: kernel_snapshot,
      session_directory: session_directory,
      service_catalog: service_catalog,
      boundary_tracker: boundary_tracker,
      signal_ingress: signal_ingress,
      invocation_supervisor: invocation_supervisor,
      projection_supervisor: projection_supervisor,
      local_supervisor: local_supervisor,
      session_server_name: unique_name(:session_server)
    }
  end

  defp seed_session_blob(session_directory, session_id, entries) do
    outbox_entries = Map.new(entries, &{&1.entry_id, &1})

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
              scope_ref:
                ScopeRef.new!(%{
                  scope_id: "scope-fault-1",
                  scope_kind: "workspace",
                  workspace_root: "/workspace",
                  environment: "test",
                  catalog_epoch: 1,
                  extensions: %{}
                }),
              signal_cursor: nil,
              recent_signal_hashes: [],
              lifecycle_status: :active,
              last_active_at: nil,
              active_plan: nil,
              active_authority_decision: nil,
              last_rejection: nil,
              boundary_ref: nil,
              outbox_entry_ids: Enum.map(entries, & &1.entry_id),
              external_refs: %{"trace_id" => "trace/#{session_id}"},
              extensions: %{}
            }),
          outbox_entries: outbox_entries,
          extensions: %{}
        })
      )
  end

  defp outbox_entry(entry_id, opts) do
    max_attempts = Keyword.get(opts, :max_attempts, 3)
    base_delay_ms = Keyword.get(opts, :base_delay_ms, 50)

    ActionOutboxEntry.new!(%{
      schema_version: 1,
      entry_id: entry_id,
      causal_group_id: "group-runtime-fault-1",
      action:
        LocalAction.new!(%{
          action_kind: "submit_invocation",
          payload: %{"entry_id" => entry_id, "payload_kind" => "runtime_fault_probe"},
          extensions: %{}
        }),
      inserted_at: ~U[2026-04-10 10:00:00Z],
      replay_status: :pending,
      durable_receipt_ref: nil,
      attempt_count: 0,
      max_attempts: max_attempts,
      backoff_policy:
        BackoffPolicy.new!(%{
          strategy: :fixed,
          base_delay_ms: base_delay_ms,
          max_delay_ms: base_delay_ms,
          linear_step_ms: nil,
          multiplier: nil,
          jitter_mode: :none,
          jitter_window_ms: 0,
          extensions: %{}
        }),
      next_attempt_at: nil,
      last_error_code: nil,
      dead_letter_reason: nil,
      ordering_mode: :strict,
      staleness_mode: :requires_check,
      staleness_requirements:
        StalenessRequirements.new!(%{
          snapshot_seq: 1,
          policy_epoch: 1,
          topology_epoch: nil,
          scope_catalog_epoch: nil,
          service_admission_epoch: nil,
          project_binding_epoch: nil,
          boundary_epoch: nil,
          required_binding_id: nil,
          required_boundary_ref: nil,
          extensions: %{}
        }),
      extensions: %{}
    })
  end

  defp attach_invocation_backlog_probe(handler_id, test_pid) do
    event_name = Telemetry.event_name(:invocation_dispatch_backlog)

    detach_telemetry_handler(handler_id)

    :ok =
      :telemetry.attach(
        handler_id,
        event_name,
        fn _event, measurements, metadata, pid ->
          send(pid, {:invocation_dispatch_backlog, measurements, metadata})
        end,
        test_pid
      )
  end

  defp detach_telemetry_handler(handler_id) do
    :telemetry.detach(handler_id)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp unique_name(prefix) do
    {:global, {__MODULE__, prefix, System.unique_integer([:positive])}}
  end

  defp wait_until(fun, attempts \\ 80)

  defp wait_until(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(25)
      wait_until(fun, attempts - 1)
    end
  end

  defp wait_until(_fun, 0) do
    flunk("condition did not become true in time")
  end

  defp run_wave12(fun) when is_function(fun, 0) do
    if wave12_enabled?(), do: fun.(), else: :ok
  end

  defp wave12_enabled? do
    System.get_env("CITADEL_REQUIRE_TOXIPROXY") == "1"
  end
end
