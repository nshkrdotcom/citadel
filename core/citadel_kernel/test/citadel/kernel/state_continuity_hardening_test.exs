defmodule Citadel.Kernel.StateContinuityHardeningTest do
  use ExUnit.Case, async: false

  @moduletag capture_log: true

  import ExUnit.CaptureLog

  alias Citadel.ActionOutboxEntry
  alias Citadel.BackoffPolicy
  alias Citadel.KernelEpochUpdate
  alias Citadel.LocalAction
  alias Citadel.PersistedSessionBlob
  alias Citadel.PersistedSessionEnvelope
  alias Citadel.Kernel.BoundaryLeaseTracker
  alias Citadel.Kernel.KernelSnapshot
  alias Citadel.Kernel.ServiceCatalog
  alias Citadel.Kernel.SessionDirectory
  alias Citadel.Kernel.SessionServer
  alias Citadel.Kernel.SignalIngress
  alias Citadel.SessionContinuityCommit
  alias Citadel.StalenessRequirements

  defmodule TestSignalSource do
    @behaviour Citadel.Ports.SignalSource

    @impl true
    def normalize_signal(observation), do: {:ok, observation}
  end

  test "kernel snapshot crashes on epoch regression instead of publishing stale snapshots" do
    kernel_snapshot_name = unique_name(:kernel_snapshot)

    pid =
      start_supervised!(
        {KernelSnapshot, name: kernel_snapshot_name, policy_version: "v5", policy_epoch: 5}
      )

    monitor = Process.monitor(pid)

    capture_log(fn ->
      KernelSnapshot.publish_epoch_update(
        kernel_snapshot_name,
        KernelEpochUpdate.new!(%{
          source_owner: "test",
          constituent: :policy_epoch,
          epoch: 4,
          updated_at: DateTime.utc_now(),
          extensions: %{"policy_version" => "v4"}
        })
      )
    end)

    assert_receive {:DOWN, ^monitor, :process, ^pid, reason}, 1_000
    assert inspect(reason) =~ "Citadel.Kernel.KernelSnapshot invariant failure"

    wait_until(fn ->
      case KernelSnapshot.read_snapshot(kernel_snapshot_name,
             staleness_class: :fresh_required,
             required_min_sequence: 0
           ) do
        {:ok, %{snapshot: %{policy_epoch: 5}, drift: :none}} -> true
        {:error, _reason} -> false
      end
    end)
  end

  test "session server crashes on impossible blocked-failure state before continuity is persisted" do
    previous_trap_exit = Process.flag(:trap_exit, true)

    kernel_snapshot_name = unique_name(:kernel_snapshot)
    session_directory_name = unique_name(:session_directory)
    service_catalog_name = unique_name(:service_catalog)
    boundary_tracker_name = unique_name(:boundary_tracker)
    signal_ingress_name = unique_name(:signal_ingress)
    invocation_supervisor_name = unique_name(:invocation_supervisor)
    projection_supervisor_name = unique_name(:projection_supervisor)
    local_supervisor_name = unique_name(:local_supervisor)

    start_supervised!({KernelSnapshot, name: kernel_snapshot_name})

    start_supervised!(
      {SessionDirectory, name: session_directory_name, kernel_snapshot: kernel_snapshot_name}
    )

    start_supervised!(
      {ServiceCatalog, name: service_catalog_name, kernel_snapshot: kernel_snapshot_name}
    )

    start_supervised!(
      {BoundaryLeaseTracker, name: boundary_tracker_name, kernel_snapshot: kernel_snapshot_name}
    )

    start_supervised!({Task.Supervisor, name: invocation_supervisor_name})
    start_supervised!({Task.Supervisor, name: projection_supervisor_name})
    start_supervised!({Task.Supervisor, name: local_supervisor_name})

    start_supervised!(
      {SignalIngress,
       name: signal_ingress_name,
       session_directory: session_directory_name,
       signal_source: TestSignalSource}
    )

    {:ok, session_server} =
      SessionServer.start_link(
        session_id: "sess-owner-guard",
        session_directory: session_directory_name,
        kernel_snapshot: kernel_snapshot_name,
        boundary_lease_tracker: boundary_tracker_name,
        service_catalog: service_catalog_name,
        signal_ingress: signal_ingress_name,
        invocation_supervisor: invocation_supervisor_name,
        projection_supervisor: projection_supervisor_name,
        local_supervisor: local_supervisor_name
      )

    monitor = Process.monitor(session_server)

    capture_log(fn ->
      assert catch_exit(
               SessionServer.commit_transition(session_server, %{
                 extensions: %{
                   "blocked_failure" => %{
                     "entry_id" => "missing-entry",
                     "reason_family" => "illegal",
                     "last_error_code" => "illegal"
                   }
                 }
               })
             )
    end)

    assert_receive {:DOWN, ^monitor, :process, ^session_server, reason}, 1_000
    assert inspect(reason) =~ "Citadel.Kernel.SessionServer invariant failure"

    assert {:ok, persisted_blob} =
             SessionDirectory.fetch_persisted_blob(session_directory_name, "sess-owner-guard")

    assert persisted_blob.envelope.continuity_revision == 1
    refute Map.has_key?(persisted_blob.envelope.extensions, "blocked_failure")

    Process.flag(:trap_exit, previous_trap_exit)
  end

  test "session continuity fencing allows one current writer and explicitly rejects stale contenders under concurrency" do
    kernel_snapshot_name = unique_name(:kernel_snapshot)
    session_directory_name = unique_name(:session_directory)

    start_supervised!({KernelSnapshot, name: kernel_snapshot_name})

    start_supervised!(
      {SessionDirectory, name: session_directory_name, kernel_snapshot: kernel_snapshot_name}
    )

    assert {:ok, %{blob: _initial_blob}} =
             SessionDirectory.claim_session(session_directory_name, "sess-contended")

    assert {:ok, %{blob: current_blob}} =
             SessionDirectory.claim_session(session_directory_name, "sess-contended")

    assert {:error, :stale_owner_incarnation} =
             SessionDirectory.commit_continuity(
               session_directory_name,
               continuity_commit(
                 current_blob,
                 "stale-owner-serial",
                 current_blob.envelope.continuity_revision,
                 current_blob.envelope.owner_incarnation - 1,
                 current_blob.envelope.continuity_revision + 1,
                 current_blob.envelope.owner_incarnation - 1
               )
             )

    valid_commits =
      for index <- 1..12 do
        continuity_commit(
          current_blob,
          "valid-#{index}",
          current_blob.envelope.continuity_revision,
          current_blob.envelope.owner_incarnation,
          current_blob.envelope.continuity_revision + 1,
          current_blob.envelope.owner_incarnation
        )
      end

    stale_owner_commits =
      for index <- 1..8 do
        continuity_commit(
          current_blob,
          "stale-owner-#{index}",
          current_blob.envelope.continuity_revision,
          current_blob.envelope.owner_incarnation - 1,
          current_blob.envelope.continuity_revision + 1,
          current_blob.envelope.owner_incarnation - 1
        )
      end

    stale_revision_commits =
      for index <- 1..8 do
        continuity_commit(
          current_blob,
          "stale-revision-#{index}",
          current_blob.envelope.continuity_revision - 1,
          current_blob.envelope.owner_incarnation,
          current_blob.envelope.continuity_revision,
          current_blob.envelope.owner_incarnation
        )
      end

    results =
      (valid_commits ++ stale_owner_commits ++ stale_revision_commits)
      |> Task.async_stream(
        &SessionDirectory.commit_continuity(session_directory_name, &1),
        ordered: false,
        max_concurrency: 28,
        timeout: 5_000
      )
      |> Enum.map(fn
        {:ok, result} -> result
        {:exit, reason} -> flunk("commit_continuity crashed unexpectedly: #{inspect(reason)}")
      end)

    assert Enum.count(results, &match?({:ok, %PersistedSessionBlob{}}, &1)) == 1
    assert Enum.any?(results, &match?({:error, :stale_continuity_revision}, &1))

    assert {:ok, persisted_blob} =
             SessionDirectory.fetch_persisted_blob(session_directory_name, "sess-contended")

    assert persisted_blob.envelope.continuity_revision ==
             current_blob.envelope.continuity_revision + 1

    [winning_entry_id] = persisted_blob.envelope.outbox_entry_ids
    assert String.starts_with?(winning_entry_id, "valid-")
  end

  defp continuity_commit(
         base_blob,
         entry_id,
         expected_continuity_revision,
         expected_owner_incarnation,
         persisted_continuity_revision,
         persisted_owner_incarnation
       ) do
    entry = replay_safe_entry(entry_id)

    persisted_blob =
      PersistedSessionBlob.new!(%{
        schema_version: 1,
        session_id: base_blob.session_id,
        envelope:
          PersistedSessionEnvelope.new!(%{
            PersistedSessionEnvelope.dump(base_blob.envelope)
            | continuity_revision: persisted_continuity_revision,
              owner_incarnation: persisted_owner_incarnation,
              outbox_entry_ids: [entry.entry_id]
          }),
        outbox_entries: %{entry.entry_id => entry},
        extensions: base_blob.extensions
      })

    SessionContinuityCommit.new!(%{
      session_id: base_blob.session_id,
      expected_continuity_revision: expected_continuity_revision,
      expected_owner_incarnation: expected_owner_incarnation,
      persisted_blob: persisted_blob,
      extensions: %{}
    })
  end

  defp replay_safe_entry(entry_id) do
    ActionOutboxEntry.new!(%{
      schema_version: 1,
      entry_id: entry_id,
      causal_group_id: "group/#{entry_id}",
      action:
        LocalAction.new!(%{
          action_kind: "submit_invocation",
          payload: %{"entry_id" => entry_id},
          extensions: %{}
        }),
      inserted_at: ~U[2026-04-10 10:00:00Z],
      replay_status: :pending,
      durable_receipt_ref: nil,
      attempt_count: 0,
      max_attempts: 2,
      backoff_policy:
        BackoffPolicy.new!(%{
          strategy: :fixed,
          base_delay_ms: 5,
          max_delay_ms: 5,
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

  defp unique_name(prefix) do
    {:global, {__MODULE__, prefix, System.unique_integer([:positive, :monotonic])}}
  end

  defp wait_until(fun, attempts \\ 40)

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
end
