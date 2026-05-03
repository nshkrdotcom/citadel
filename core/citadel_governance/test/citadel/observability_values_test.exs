defmodule Citadel.ObservabilityValuesTest do
  use ExUnit.Case, async: true

  alias Citadel.BridgeCircuit
  alias Citadel.BridgeCircuitPolicy
  alias Citadel.MemoryRecord
  alias Citadel.ObservabilityContract.CardinalityBounds
  alias Citadel.RuntimeObservation
  alias Citadel.ScopeRef
  alias Citadel.TraceEnvelope
  alias Jido.Integration.V2.SubjectRef

  test "runtime observation rejects duplicated lineage keys in payload" do
    subject_ref = SubjectRef.new!(%{kind: :run, id: "run-1"})

    assert_raise ArgumentError, fn ->
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
        payload: %{"subject_ref" => "copied"},
        subject_ref: subject_ref,
        evidence_refs: [],
        governance_refs: [],
        extensions: %{}
      })
    end
  end

  test "runtime observations expose stable read and wake surfaces" do
    subject_ref = SubjectRef.new!(%{kind: :attempt, id: "attempt-1"})

    observation =
      RuntimeObservation.new!(%{
        observation_id: "obs-1",
        request_id: "req-1",
        session_id: "sess-1",
        signal_id: "sig-1",
        signal_cursor: "cursor-1",
        runtime_ref_id: "runtime-1",
        event_kind: "execution_event",
        event_at: ~U[2026-04-10 10:00:00Z],
        status: "completed",
        output: %{"result" => "done"},
        artifacts: [],
        payload: %{"phase" => "done"},
        subject_ref: subject_ref,
        evidence_refs: [],
        governance_refs: [],
        extensions: %{}
      })

    assert RuntimeObservation.stable_read_fields() == [
             :observation_id,
             :request_id,
             :session_id,
             :signal_id,
             :signal_cursor,
             :runtime_ref_id,
             :event_kind,
             :event_at,
             :status,
             :subject_ref,
             :evidence_refs,
             :governance_refs
           ]

    assert RuntimeObservation.wake_reason(observation) == %{
             event_kind: "execution_event",
             status: "completed",
             subject_kind: :attempt,
             subject_id: "attempt-1"
           }

    assert RuntimeObservation.read_descriptor(observation) == %{
             observation_id: "obs-1",
             request_id: "req-1",
             session_id: "sess-1",
             signal_id: "sig-1",
             signal_cursor: "cursor-1",
             runtime_ref_id: "runtime-1",
             event_kind: "execution_event",
             event_at: ~U[2026-04-10 10:00:00Z],
             status: "completed",
             subject_ref: SubjectRef.dump(subject_ref),
             evidence_ref_count: 0,
             governance_ref_count: 0
           }
  end

  test "trace envelope enforces canonical minimum family names and payload hygiene" do
    assert_raise ArgumentError, fn ->
      TraceEnvelope.new!(%{
        trace_envelope_id: "trace-env-1",
        record_kind: :event,
        family: "session_attached",
        name: "wrong.name",
        phase: "post_commit",
        trace_id: "trace-1",
        tenant_id: "tenant-1",
        session_id: "sess-1",
        request_id: "req-1",
        decision_id: "dec-1",
        snapshot_seq: 1,
        signal_id: nil,
        outbox_entry_id: nil,
        boundary_ref: nil,
        span_id: nil,
        parent_span_id: nil,
        occurred_at: ~U[2026-04-10 10:00:00Z],
        started_at: nil,
        finished_at: nil,
        status: "ok",
        attributes: %{},
        extensions: %{}
      })
    end

    envelope =
      TraceEnvelope.new!(
        trace_envelope_attrs("trace-env-2",
          attributes: %{"raw_text" => "open the repo"},
          extensions: %{}
        )
      )

    refute Map.has_key?(envelope.attributes, "raw_text")
    refute inspect(envelope.attributes) =~ "open the repo"

    assert %{
             "artifact_kind" => "trace_attribute_overflow_summary",
             "overflow_reasons" => ["raw_payload_field"],
             "spillover_count" => 1
           } = Map.fetch!(envelope.attributes, TraceEnvelope.trace_attribute_overflow_key())
  end

  test "trace envelope spills oversized values and bounds collection shape" do
    profile = CardinalityBounds.profile!(:trace_event)

    envelope =
      TraceEnvelope.new!(
        trace_envelope_attrs("trace-env-spill",
          attributes: %{
            "safe_detail" => String.duplicate("x", profile.max_attribute_value_bytes + 1),
            "raw_webhook_body" => %{"secret" => "do not inline"},
            "wide_list" => Enum.to_list(1..(profile.max_collection_items + 1)),
            "deep_map" => deep_trace_map(profile.max_map_depth + 1)
          },
          extensions: %{
            "canonical_idempotency_key" => "idem:v1:session-attached",
            "provider_response" => %{"body" => "do not inline"}
          }
        )
      )

    assert %{"artifact_kind" => "trace_attribute_spillover", "overflow_reason" => "value_bytes"} =
             envelope.attributes["safe_detail"]

    assert %{
             "artifact_kind" => "trace_attribute_spillover",
             "overflow_reason" => "collection_size"
           } = envelope.attributes["wide_list"]

    assert %{"artifact_kind" => "trace_attribute_spillover", "overflow_reason" => "map_depth"} =
             get_in(envelope.attributes, ["deep_map", "child", "child", "child", "child"])

    refute Map.has_key?(envelope.attributes, "raw_webhook_body")
    refute inspect(envelope.attributes) =~ "do not inline"

    assert %{"overflow_reasons" => ["raw_payload_field"], "spillover_count" => 1} =
             Map.fetch!(envelope.attributes, TraceEnvelope.trace_attribute_overflow_key())

    assert envelope.extensions["canonical_idempotency_key"] == "idem:v1:session-attached"
    refute Map.has_key?(envelope.extensions, "provider_response")

    assert %{"overflow_reasons" => ["raw_payload_field"], "spillover_count" => 1} =
             Map.fetch!(envelope.extensions, TraceEnvelope.trace_extension_overflow_key())
  end

  test "trace envelope caps top-level attribute count and oversized keys" do
    profile = CardinalityBounds.profile!(:trace_event)

    oversized_key = String.duplicate("k", profile.max_attribute_key_bytes + 1)

    attributes =
      Enum.into(
        1..(profile.max_attributes_per_span + 8),
        %{oversized_key => "hidden"},
        fn index ->
          {"z_attr_#{index}", index}
        end
      )

    envelope =
      TraceEnvelope.new!(
        trace_envelope_attrs("trace-env-count",
          attributes: attributes,
          extensions: %{}
        )
      )

    assert map_size(envelope.attributes) == profile.max_attributes_per_span
    refute Map.has_key?(envelope.attributes, oversized_key)

    assert %{
             "artifact_kind" => "trace_attribute_overflow_summary",
             "overflow_reasons" => reasons,
             "spillover_count" => spillover_count
           } = Map.fetch!(envelope.attributes, TraceEnvelope.trace_attribute_overflow_key())

    assert "attribute_count" in reasons
    assert "key_bytes" in reasons
    assert spillover_count > 0
  end

  test "required minimum families remain event-shaped while spans stay additive" do
    assert_raise ArgumentError, fn ->
      TraceEnvelope.new!(%{
        trace_envelope_id: "trace-env-3",
        record_kind: :span,
        family: "invocation_submitted",
        name: "citadel.invocation.submitted",
        phase: "post_commit",
        trace_id: "trace-1",
        tenant_id: "tenant-1",
        session_id: "sess-1",
        request_id: "req-1",
        decision_id: nil,
        snapshot_seq: nil,
        signal_id: nil,
        outbox_entry_id: "entry-1",
        boundary_ref: nil,
        span_id: "span-1",
        parent_span_id: nil,
        occurred_at: nil,
        started_at: ~U[2026-04-10 10:00:00Z],
        finished_at: ~U[2026-04-10 10:00:01Z],
        status: "ok",
        attributes: %{},
        extensions: %{}
      })
    end

    span =
      TraceEnvelope.new!(%{
        trace_envelope_id: "trace-env-4",
        record_kind: :span,
        family: "decision_task",
        name: "citadel.span.decision_task",
        phase: "post_commit",
        trace_id: "trace-1",
        tenant_id: "tenant-1",
        session_id: "sess-1",
        request_id: "req-1",
        decision_id: "dec-1",
        snapshot_seq: 1,
        signal_id: nil,
        outbox_entry_id: nil,
        boundary_ref: nil,
        span_id: "span-1",
        parent_span_id: nil,
        occurred_at: nil,
        started_at: ~U[2026-04-10 10:00:00Z],
        finished_at: ~U[2026-04-10 10:00:01Z],
        status: "ok",
        attributes: %{"duration_bucket" => "fast"},
        extensions: %{}
      })

    assert span.record_kind == :span
  end

  test "bridge circuit opens and fast-fails by scoped downstream key" do
    {:ok, clock} = Agent.start_link(fn -> 0 end)

    circuit =
      BridgeCircuit.new!(
        policy:
          BridgeCircuitPolicy.new!(%{
            failure_threshold: 2,
            window_ms: 100,
            cooldown_ms: 50,
            half_open_max_inflight: 1,
            scope_key_mode: "downstream_scope",
            extensions: %{}
          }),
        now_ms_fun: fn -> Agent.get(clock, & &1) end
      )

    circuit = BridgeCircuit.record_failure(circuit, "scope-a")
    circuit = BridgeCircuit.record_failure(circuit, "scope-a")

    assert {{:error, :circuit_open}, _circuit} = BridgeCircuit.allow(circuit, "scope-a")
    assert {:ok, _circuit} = BridgeCircuit.allow(circuit, "scope-b")

    Agent.update(clock, fn _ -> 60 end)
    assert {:ok, circuit} = BridgeCircuit.allow(circuit, "scope-a")
    assert BridgeCircuit.scope_state(circuit, "scope-a").status == :half_open
  end

  test "memory records remain advisory but keep explicit lexical ids" do
    scope_ref =
      ScopeRef.new!(%{
        scope_id: "scope-1",
        scope_kind: "workspace",
        workspace_root: "/workspace",
        environment: "test",
        catalog_epoch: 1,
        extensions: %{}
      })

    record =
      MemoryRecord.new!(%{
        memory_id: "memory-1",
        scope_ref: scope_ref,
        session_id: "sess-1",
        kind: "summary",
        summary: "Prior run state",
        subject_links: [SubjectRef.ref(:run, "run-1")],
        evidence_links: ["jido://v2/evidence/event/event-1"],
        expires_at: nil,
        confidence: 0.9,
        metadata: %{"advisory" => true}
      })

    assert record.memory_id == "memory-1"
    assert record.metadata["advisory"] == true
  end

  defp trace_envelope_attrs(trace_envelope_id, overrides) do
    %{
      trace_envelope_id: trace_envelope_id,
      record_kind: :event,
      family: "session_attached",
      name: "citadel.session.attached",
      phase: "post_commit",
      trace_id: "trace-1",
      tenant_id: "tenant-1",
      session_id: "sess-1",
      request_id: "req-1",
      decision_id: nil,
      snapshot_seq: 1,
      signal_id: nil,
      outbox_entry_id: nil,
      boundary_ref: nil,
      span_id: nil,
      parent_span_id: nil,
      occurred_at: ~U[2026-04-10 10:00:00Z],
      started_at: nil,
      finished_at: nil,
      status: "ok",
      attributes: %{},
      extensions: %{}
    }
    |> Map.merge(Map.new(overrides))
  end

  defp deep_trace_map(depth), do: deep_trace_map(depth, %{"leaf" => "value"})
  defp deep_trace_map(0, value), do: value
  defp deep_trace_map(depth, value), do: %{"child" => deep_trace_map(depth - 1, value)}
end
