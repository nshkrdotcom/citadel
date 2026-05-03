defmodule Citadel.ProjectionBridgeTest do
  use ExUnit.Case, async: true

  alias Citadel.ActionOutboxEntry
  alias Citadel.BackoffPolicy
  alias Citadel.LocalAction
  alias Citadel.ProjectionBridge
  alias Citadel.RuntimeObservation
  alias Citadel.StalenessRequirements
  alias Jido.Integration.V2.DerivedStateAttachment
  alias Jido.Integration.V2.EvidenceRef
  alias Jido.Integration.V2.GovernanceRef
  alias Jido.Integration.V2.SubjectRef

  defmodule Downstream do
    def publish_review_projection(projection, metadata) do
      send(Process.get(:projection_bridge_test_pid), {:review_projection, projection, metadata})
      {:ok, "review:#{metadata.entry_id}"}
    end

    def publish_derived_state_attachment(attachment, metadata) do
      send(
        Process.get(:projection_bridge_test_pid),
        {:derived_state_attachment, attachment, metadata}
      )

      {:ok, "attachment:#{metadata.entry_id}"}
    end
  end

  setup do
    Process.put(:projection_bridge_test_pid, self())
    :ok
  end

  test "adapts runtime observations into review projections and deduplicates by entry_id" do
    bridge = ProjectionBridge.new!(downstream: Downstream)
    entry = outbox_entry("entry-review")
    observation = runtime_observation()

    assert {:ok, "review:entry-review", bridge_after_publish} =
             ProjectionBridge.publish_review_projection(bridge, observation, entry)

    assert_receive {:review_projection, projection,
                    %{entry_id: "entry-review", causal_group_id: "group-1"}}

    assert projection.packet_ref == "packet-1"
    assert projection.subject == observation.subject_ref
    assert length(projection.evidence_refs) == 1

    assert {:ok, "review:entry-review", ^bridge_after_publish} =
             ProjectionBridge.publish_review_projection(bridge_after_publish, observation, entry)

    refute_receive {:review_projection, _projection, _metadata}
  end

  test "publishes shared derived-state attachments separately from invocation flow" do
    bridge = ProjectionBridge.new!(downstream: Downstream)
    entry = outbox_entry("entry-attachment")

    attachment =
      DerivedStateAttachment.new!(%{
        subject: SubjectRef.new!(%{kind: :run, id: "run-1"}),
        evidence_refs: [
          EvidenceRef.new!(%{
            kind: :event,
            id: "event-1",
            packet_ref: "packet-1",
            subject: SubjectRef.new!(%{kind: :event, id: "event-1"})
          })
        ],
        governance_refs: [],
        metadata: %{"kind" => "derived_summary"}
      })

    assert {:ok, "attachment:entry-attachment", _bridge} =
             ProjectionBridge.publish_derived_state_attachment(bridge, attachment, entry)

    assert_receive {:derived_state_attachment, published_attachment,
                    %{entry_id: "entry-attachment", causal_group_id: "group-1"}}

    assert published_attachment.metadata["kind"] == "derived_summary"
  end

  test "shares publication deduplication across fresh bridge instances when state_name is reused" do
    state_name = unique_name(:projection_bridge_state)
    entry = outbox_entry("entry-shared")
    observation = runtime_observation()

    bridge =
      ProjectionBridge.new!(
        downstream: Downstream,
        state_name: state_name
      )

    assert {:ok, "review:entry-shared", _bridge} =
             ProjectionBridge.publish_review_projection(bridge, observation, entry)

    assert_receive {:review_projection, _projection, %{entry_id: "entry-shared"}}

    fresh_bridge =
      ProjectionBridge.new!(
        downstream: Downstream,
        state_name: state_name
      )

    assert {:ok, "review:entry-shared", _fresh_bridge} =
             ProjectionBridge.publish_review_projection(fresh_bridge, observation, entry)

    refute_receive {:review_projection, _projection, _metadata}
  end

  defp runtime_observation do
    RuntimeObservation.new!(%{
      observation_id: "obs-1",
      request_id: "req-1",
      session_id: "sess-1",
      signal_id: "sig-1",
      signal_cursor: "cursor-1",
      runtime_ref_id: "runtime-1",
      event_kind: "execution_event",
      event_at: ~U[2026-04-10 10:00:00Z],
      status: "ok",
      output: %{"result" => "done"},
      artifacts: [],
      payload: %{"phase" => "done"},
      subject_ref: SubjectRef.new!(%{kind: :run, id: "run-1"}),
      evidence_refs: [
        EvidenceRef.new!(%{
          kind: :event,
          id: "event-1",
          packet_ref: "packet-1",
          subject: SubjectRef.new!(%{kind: :event, id: "event-1"})
        })
      ],
      governance_refs: [
        GovernanceRef.new!(%{
          kind: :policy_decision,
          id: "governance-1",
          subject: SubjectRef.new!(%{kind: :run, id: "run-1"}),
          evidence: [],
          metadata: %{}
        })
      ],
      extensions: %{}
    })
  end

  defp outbox_entry(entry_id) do
    ActionOutboxEntry.new!(%{
      schema_version: 1,
      entry_id: entry_id,
      causal_group_id: "group-1",
      action:
        LocalAction.new!(%{
          action_kind: "publish_projection",
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
          max_delay_ms: 10,
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

  defp unique_name(prefix) do
    {:global, {__MODULE__, prefix, System.unique_integer([:positive])}}
  end
end
