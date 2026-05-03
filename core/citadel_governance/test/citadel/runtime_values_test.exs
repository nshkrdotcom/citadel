defmodule Citadel.RuntimeValuesTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Citadel.ActionOutboxEntry
  alias Citadel.BackoffPolicy
  alias Citadel.LocalAction
  alias Citadel.PersistedSessionBlob
  alias Citadel.PersistedSessionEnvelope
  alias Citadel.SessionContinuityCommit
  alias Citadel.SessionOutbox
  alias Citadel.StalenessRequirements

  property "backoff delay remains deterministic for the same entry id and attempt history" do
    check all(attempt_count <- StreamData.integer(0..10)) do
      policy =
        BackoffPolicy.new!(%{
          strategy: :exponential,
          base_delay_ms: 100,
          max_delay_ms: 5_000,
          linear_step_ms: nil,
          multiplier: 2,
          jitter_mode: :entry_stable,
          jitter_window_ms: 75,
          extensions: %{}
        })

      assert BackoffPolicy.compute_delay_ms!(policy, "entry-1", attempt_count) ==
               BackoffPolicy.compute_delay_ms!(policy, "entry-1", attempt_count)
    end
  end

  property "session outbox preserves the one-to-one invariant across live writes" do
    check all(
            ids <-
              StreamData.uniq_list_of(StreamData.integer(1..100), min_length: 1, max_length: 6)
          ) do
      entries = Enum.map(ids, &outbox_entry/1)
      outbox = SessionOutbox.from_entries!(entries)

      assert SessionOutbox.invariant?(outbox)

      deleted =
        ids
        |> Enum.take(div(length(ids), 2))
        |> Enum.reduce(outbox, fn id, acc ->
          SessionOutbox.delete_entry!(acc, "entry-#{id}")
        end)

      assert SessionOutbox.invariant?(deleted)

      restored =
        Enum.take(ids, div(length(ids), 2))
        |> Enum.reduce(deleted, fn id, acc ->
          SessionOutbox.put_entry!(acc, outbox_entry(id))
        end)

      assert SessionOutbox.invariant?(restored)
    end
  end

  test "staleness requirements reject snapshot-seq-only checks" do
    assert_raise ArgumentError, fn ->
      StalenessRequirements.new!(%{
        snapshot_seq: 10,
        policy_epoch: nil,
        topology_epoch: nil,
        scope_catalog_epoch: nil,
        service_admission_epoch: nil,
        project_binding_epoch: nil,
        boundary_epoch: nil,
        required_binding_id: nil,
        required_boundary_ref: nil,
        extensions: %{}
      })
    end
  end

  test "persisted session blob restores the live session outbox in stored order" do
    first = outbox_entry(1)
    second = outbox_entry(2)

    blob =
      PersistedSessionBlob.new!(%{
        schema_version: 1,
        session_id: "sess-1",
        envelope:
          PersistedSessionEnvelope.new!(%{
            schema_version: 1,
            session_id: "sess-1",
            continuity_revision: 4,
            owner_incarnation: 2,
            project_binding: nil,
            scope_ref: nil,
            signal_cursor: nil,
            recent_signal_hashes: ["signal-1"],
            lifecycle_status: :active,
            last_active_at: nil,
            active_plan: nil,
            active_authority_decision: nil,
            last_rejection: nil,
            boundary_ref: "boundary-ref-1",
            outbox_entry_ids: [first.entry_id, second.entry_id],
            external_refs: %{},
            extensions: %{}
          }),
        outbox_entries: %{
          first.entry_id => first,
          second.entry_id => second
        },
        extensions: %{}
      })

    restored = PersistedSessionBlob.restore_session_outbox!(blob)

    assert restored.entry_order == [first.entry_id, second.entry_id]
    assert SessionOutbox.invariant?(restored)
  end

  test "continuity commit enforces single-step revision advancement" do
    entry = outbox_entry(1)

    persisted_blob =
      PersistedSessionBlob.new!(%{
        schema_version: 1,
        session_id: "sess-1",
        envelope:
          PersistedSessionEnvelope.new!(%{
            schema_version: 1,
            session_id: "sess-1",
            continuity_revision: 5,
            owner_incarnation: 3,
            project_binding: nil,
            scope_ref: nil,
            signal_cursor: nil,
            recent_signal_hashes: [],
            lifecycle_status: :active,
            last_active_at: nil,
            active_plan: nil,
            active_authority_decision: nil,
            last_rejection: nil,
            boundary_ref: nil,
            outbox_entry_ids: [entry.entry_id],
            external_refs: %{},
            extensions: %{}
          }),
        outbox_entries: %{entry.entry_id => entry},
        extensions: %{}
      })

    commit =
      SessionContinuityCommit.new!(%{
        session_id: "sess-1",
        expected_continuity_revision: 4,
        expected_owner_incarnation: 3,
        persisted_blob: persisted_blob,
        extensions: %{}
      })

    assert SessionContinuityCommit.owner_transition(commit) == :same_owner
  end

  defp outbox_entry(id) do
    ActionOutboxEntry.new!(%{
      schema_version: 1,
      entry_id: "entry-#{id}",
      causal_group_id: "group-1",
      action:
        LocalAction.new!(%{
          action_kind: "submit_invocation",
          payload: %{"entry" => id},
          extensions: %{}
        }),
      inserted_at: ~U[2026-04-10 10:00:00Z],
      replay_status: :pending,
      durable_receipt_ref: nil,
      attempt_count: 0,
      max_attempts: 5,
      backoff_policy:
        BackoffPolicy.new!(%{
          strategy: :linear,
          base_delay_ms: 100,
          max_delay_ms: 2_000,
          linear_step_ms: 50,
          multiplier: nil,
          jitter_mode: :entry_stable,
          jitter_window_ms: 25,
          extensions: %{}
        }),
      next_attempt_at: nil,
      last_error_code: nil,
      dead_letter_reason: nil,
      ordering_mode: :strict,
      staleness_mode: :requires_check,
      staleness_requirements:
        StalenessRequirements.new!(%{
          snapshot_seq: 10,
          policy_epoch: 3,
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
end
