defmodule Citadel.Kernel.SessionMigrationTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  @moduletag capture_log: true

  import ExUnit.CaptureLog

  alias Citadel.ActionOutboxEntry
  alias Citadel.BackoffPolicy
  alias Citadel.LocalAction
  alias Citadel.PersistedSessionBlob
  alias Citadel.Kernel.KernelSnapshot
  alias Citadel.Kernel.SessionDirectory
  alias Citadel.StalenessRequirements

  property "claim_session migrates prior-version continuity blobs and preserves lineage and correlation fields" do
    kernel_snapshot_name = unique_name(:kernel_snapshot)
    session_directory_name = unique_name(:session_directory)

    start_supervised!({KernelSnapshot, name: kernel_snapshot_name})

    start_supervised!(
      {SessionDirectory, name: session_directory_name, kernel_snapshot: kernel_snapshot_name}
    )

    check all(legacy_blob <- legacy_blob_generator(), max_runs: 40) do
      session_id = Map.fetch!(legacy_blob, :session_id)
      expected_external_refs = expected_external_refs(legacy_blob)
      expected_outbox_entry_ids = expected_outbox_entry_ids(legacy_blob)
      expected_continuity_revision = expected_continuity_revision(legacy_blob)
      expected_owner_incarnation = expected_owner_incarnation(legacy_blob)

      assert :ok = SessionDirectory.reset!(session_directory_name)
      assert :ok = SessionDirectory.seed_raw_blob(session_directory_name, session_id, legacy_blob)

      assert {:ok, %{blob: claimed_blob, lifecycle_event: :resumed}} =
               SessionDirectory.claim_session(session_directory_name, session_id)

      assert claimed_blob.envelope.schema_version == 1
      assert claimed_blob.schema_version == 1
      assert claimed_blob.session_id == session_id
      assert claimed_blob.envelope.session_id == session_id
      assert claimed_blob.envelope.continuity_revision == expected_continuity_revision + 1
      assert claimed_blob.envelope.owner_incarnation == expected_owner_incarnation + 1
      assert claimed_blob.envelope.outbox_entry_ids == expected_outbox_entry_ids
      assert claimed_blob.envelope.external_refs == expected_external_refs

      assert PersistedSessionBlob.restore_session_outbox!(claimed_blob).entry_order ==
               expected_outbox_entry_ids
    end
  end

  test "schema 0 continuity maps without explicit outbox order fail fast instead of normalizing corruption" do
    kernel_snapshot_name = unique_name(:kernel_snapshot)
    store_key = {__MODULE__, :impossible_store, System.unique_integer([:positive])}
    session_directory_name = unique_name(:session_directory)

    start_supervised!({KernelSnapshot, name: kernel_snapshot_name})

    start_supervised!(
      {SessionDirectory,
       name: session_directory_name, kernel_snapshot: kernel_snapshot_name, store_key: store_key}
    )

    before_store = :persistent_term.get(store_key, :missing)

    impossible_blob = %{
      schema_version: 0,
      session_id: "sess-impossible",
      continuity_revision: 4,
      owner_incarnation: 2,
      outbox_entries: %{
        "entry-a" => legacy_entry_map("entry-a"),
        "entry-b" => legacy_entry_map("entry-b")
      },
      external_refs: %{
        "trace_id" => "trace-impossible",
        "subject_ref" => %{"kind" => "run", "id" => "run-impossible"},
        "evidence_refs" => ["evidence-impossible"],
        "governance_refs" => ["governance-impossible"]
      },
      extensions: %{"legacy" => true}
    }

    capture_log(fn ->
      assert catch_exit(
               SessionDirectory.seed_raw_blob(
                 session_directory_name,
                 impossible_blob.session_id,
                 impossible_blob
               )
             )
    end)

    assert :persistent_term.get(store_key, :missing) == before_store
  end

  defp legacy_blob_generator do
    gen all(
          numeric_id <- StreamData.integer(1..10_000),
          continuity_revision <- StreamData.integer(0..20),
          owner_incarnation <- StreamData.integer(1..10),
          entry_ids <-
            StreamData.uniq_list_of(StreamData.integer(1..50), min_length: 0, max_length: 4),
          outbox_shape <-
            StreamData.member_of([:explicit_ids_map, :ordered_list, :single_map_without_ids]),
          continuity_source <- StreamData.member_of([:envelope, :root]),
          owner_source <- StreamData.member_of([:envelope, :root]),
          external_refs_source <- StreamData.member_of([:envelope, :root]),
          signal_cursor <-
            StreamData.one_of([
              StreamData.constant(nil),
              StreamData.map(StreamData.integer(1..20), &"cursor-#{&1}")
            ]),
          boundary_ref <-
            StreamData.one_of([
              StreamData.constant(nil),
              StreamData.map(StreamData.integer(1..20), &"boundary-#{&1}")
            ]),
          lifecycle_status <-
            StreamData.member_of([:active, :idle, :completed, :resume_pending, :blocked])
        ) do
      session_id = "sess-#{numeric_id}"
      ordered_entry_ids = Enum.map(entry_ids, &"entry-#{&1}")
      ordered_entries = Enum.map(ordered_entry_ids, &legacy_entry_map/1)

      external_refs = %{
        "trace_id" => "trace-#{numeric_id}",
        "subject_ref" => %{"kind" => "run", "id" => "run-#{numeric_id}"},
        "evidence_refs" => Enum.map(ordered_entry_ids, &"evidence/#{&1}"),
        "governance_refs" => Enum.map(ordered_entry_ids, &"governance/#{&1}")
      }

      {outbox_entries, outbox_entry_ids} =
        case outbox_shape do
          :explicit_ids_map ->
            {Map.new(ordered_entries, &{Map.fetch!(&1, :entry_id), &1}), ordered_entry_ids}

          :ordered_list ->
            {ordered_entries, nil}

          :single_map_without_ids ->
            selected_entries = Enum.take(ordered_entries, 1)
            {Map.new(selected_entries, &{Map.fetch!(&1, :entry_id), &1}), nil}
        end

      envelope =
        %{
          session_id: session_id,
          signal_cursor: signal_cursor,
          recent_signal_hashes: ordered_entry_ids,
          lifecycle_status: lifecycle_status,
          last_active_at: ~U[2026-04-10 10:00:00Z],
          boundary_ref: boundary_ref,
          extensions: %{"legacy_marker" => "schema-0"}
        }
        |> maybe_put(continuity_source == :envelope, :continuity_revision, continuity_revision)
        |> maybe_put(owner_source == :envelope, :owner_incarnation, owner_incarnation)
        |> maybe_put(external_refs_source == :envelope, :external_refs, external_refs)
        |> maybe_put(outbox_entry_ids != nil, :outbox_entry_ids, outbox_entry_ids)

      %{
        schema_version: 0,
        session_id: session_id,
        envelope: envelope,
        outbox_entries: outbox_entries,
        extensions: %{"legacy_blob" => true}
      }
      |> maybe_put(continuity_source == :root, :continuity_revision, continuity_revision)
      |> maybe_put(owner_source == :root, :owner_incarnation, owner_incarnation)
      |> maybe_put(external_refs_source == :root, :external_refs, external_refs)
      |> maybe_put(
        outbox_entry_ids != nil and continuity_source == :root,
        :outbox_entry_ids,
        outbox_entry_ids
      )
    end
  end

  defp expected_external_refs(legacy_blob) do
    legacy_blob
    |> get_in([:envelope, :external_refs])
    |> case do
      nil -> Map.get(legacy_blob, :external_refs, %{})
      refs -> refs
    end
  end

  defp expected_outbox_entry_ids(legacy_blob) do
    cond do
      is_list(get_in(legacy_blob, [:envelope, :outbox_entry_ids])) ->
        get_in(legacy_blob, [:envelope, :outbox_entry_ids])

      is_list(Map.get(legacy_blob, :outbox_entry_ids)) ->
        Map.fetch!(legacy_blob, :outbox_entry_ids)

      is_list(legacy_blob.outbox_entries) ->
        Enum.map(legacy_blob.outbox_entries, &Map.fetch!(&1, :entry_id))

      is_map(legacy_blob.outbox_entries) ->
        Map.keys(legacy_blob.outbox_entries)

      true ->
        []
    end
  end

  defp expected_continuity_revision(legacy_blob) do
    get_in(legacy_blob, [:envelope, :continuity_revision]) ||
      Map.fetch!(legacy_blob, :continuity_revision)
  end

  defp expected_owner_incarnation(legacy_blob) do
    get_in(legacy_blob, [:envelope, :owner_incarnation]) ||
      Map.fetch!(legacy_blob, :owner_incarnation)
  end

  defp legacy_entry_map(entry_id) do
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
      max_attempts: 3,
      backoff_policy:
        BackoffPolicy.new!(%{
          strategy: :fixed,
          base_delay_ms: 10,
          max_delay_ms: 50,
          linear_step_ms: nil,
          multiplier: nil,
          jitter_mode: :entry_stable,
          jitter_window_ms: 5,
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
    |> ActionOutboxEntry.dump()
    |> Map.put(:schema_version, 0)
  end

  defp maybe_put(map, true, key, value), do: Map.put(map, key, value)
  defp maybe_put(map, false, _key, _value), do: map

  defp unique_name(prefix) do
    {:global, {__MODULE__, prefix, System.unique_integer([:positive, :monotonic])}}
  end
end
