defmodule Citadel.Conformance.TelemetryAndContractGateTest do
  use ExUnit.Case, async: false

  alias Citadel.ActionOutboxEntry
  alias Citadel.BackoffPolicy
  alias Citadel.Conformance
  alias Citadel.LocalAction
  alias Citadel.ObservabilityContract.Telemetry
  alias Citadel.PersistedSessionBlob
  alias Citadel.PersistedSessionEnvelope
  alias Citadel.Kernel.KernelSnapshot
  alias Citadel.Kernel.SessionDirectory

  defmodule TelemetryForwarder do
    def handle_event(event_name, measurements, metadata, test_pid) do
      send(test_pid, {:telemetry_event, event_name, measurements, metadata})
    end
  end

  setup do
    kernel_snapshot = unique_name(:kernel_snapshot)
    session_directory = unique_name(:session_directory)

    start_supervised!({KernelSnapshot, name: kernel_snapshot})

    start_supervised!(
      {SessionDirectory, name: session_directory, kernel_snapshot: kernel_snapshot}
    )

    {:ok, kernel_snapshot: kernel_snapshot, session_directory: session_directory}
  end

  test "emits the minimum lifecycle, quarantine, blocked-session, and bulk-recovery telemetry families",
       %{
         session_directory: session_directory
       } do
    handler_id = "conformance-telemetry-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(
        handler_id,
        Telemetry.definitions() |> Map.values() |> Enum.map(& &1.event_name),
        &TelemetryForwarder.handle_event/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, %{lifecycle_event: :attached}} =
             normalize_lifecycle_result(
               SessionDirectory.claim_session(session_directory, "sess-telemetry")
             )

    seed_dead_lettered_session(
      session_directory,
      "sess-blocked",
      "entry-blocked",
      "projection_backend_down"
    )

    assert :ok =
             SessionDirectory.quarantine_session(
               session_directory,
               "sess-blocked",
               "boundary_resume_failed"
             )

    assert {:ok, 1} =
             SessionDirectory.bulk_recover_dead_letters(
               session_directory,
               [dead_letter_reason: "projection_backend_down", ordering_mode: :strict],
               {:retry_with_override, "operator retry"}
             )

    lifecycle_event = Telemetry.event_name(:session_lifecycle_count)
    blocked_event = Telemetry.event_name(:blocked_session_count)
    blocked_alert_event = Telemetry.event_name(:blocked_session_alert_count)
    quarantined_event = Telemetry.event_name(:quarantined_session_count)
    bulk_recovery_event = Telemetry.event_name(:dead_letter_bulk_recovery)

    assert_receive {:telemetry_event, ^lifecycle_event, %{count: 1},
                    %{lifecycle_event: :attached}}

    assert_receive {:telemetry_event, ^blocked_event, %{count: 1},
                    %{reason_family: "projection_backend_down"}}

    assert_receive {:telemetry_event, ^blocked_alert_event, %{count: 1},
                    %{strict_dead_letter_family: "projection_backend_down"}}

    assert_receive {:telemetry_event, ^quarantined_event, %{count: 1}, %{}}

    assert_receive {:telemetry_event, ^bulk_recovery_event,
                    %{operation_count: 1, affected_entry_count: 1}, %{}}
  end

  test "keeps an explicit published-artifact compatibility gate for shared contracts" do
    assert Code.ensure_loaded?(Jido.Integration.V2.ReviewProjection)
    assert Code.ensure_loaded?(Jido.Integration.V2.DerivedStateAttachment)

    case Conformance.requested_contract_mode() do
      :published_artifact ->
        assert Conformance.shared_contract_mode() == :published_artifact

      :staged_artifact ->
        assert Conformance.shared_contract_mode() == :staged_artifact

      :path_local ->
        assert Conformance.shared_contract_mode() == :path_local
    end
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

  defp normalize_lifecycle_result({:ok, %{lifecycle_event: lifecycle_event}}) do
    {:ok, %{lifecycle_event: lifecycle_event}}
  end

  defp normalize_lifecycle_result(other), do: other
end
