defmodule Citadel.TraceBridgeTest do
  use ExUnit.Case, async: false

  alias AITrace.Span
  alias Citadel.ObservabilityContract.CardinalityBounds
  alias Citadel.TraceBridge
  alias Citadel.TraceEnvelope

  defmodule TestExporter do
    @behaviour AITrace.Exporter

    @impl true
    def init(opts), do: {:ok, opts}

    @impl true
    def export(trace, state) do
      send(state.test_pid, {:exported_trace, trace})
      {:ok, state}
    end

    @impl true
    def shutdown(_state), do: :ok
  end

  defmodule AmbientExporter do
    @behaviour AITrace.Exporter

    @impl true
    def init(opts), do: {:ok, opts}

    @impl true
    def export(trace, state) do
      send(state.test_pid, {:ambient_exported_trace, trace})
      {:ok, state}
    end

    @impl true
    def shutdown(_state), do: :ok
  end

  defmodule AmbientAdapter do
    @moduledoc false

    def publish_trace(envelope) do
      send(Process.get(:trace_bridge_test_pid), {:ambient_adapter_trace, envelope})
      :ok
    end

    def publish_traces(envelopes) do
      send(Process.get(:trace_bridge_test_pid), {:ambient_adapter_traces, envelopes})
      :ok
    end
  end

  setup do
    Process.put(:trace_bridge_test_pid, self())
    :ok
  end

  test "translates event envelopes into AITrace traces" do
    envelope =
      TraceEnvelope.new!(%{
        trace_envelope_id: "env-1",
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
        boundary_ref: "boundary-ref-1",
        span_id: nil,
        parent_span_id: nil,
        occurred_at: ~U[2026-04-10 10:00:00Z],
        started_at: nil,
        finished_at: nil,
        status: "ok",
        attributes: %{"attach_mode" => "fresh_or_reuse"},
        extensions: %{
          "canonical_idempotency_key" => "idem:v1:session-attached",
          "platform_envelope_id" => "intent-session-attached"
        }
      })

    assert :ok = TraceBridge.publish_trace(envelope, trace_bridge_opts())
    assert_receive {:exported_trace, trace}
    assert trace.trace_id == "trace-1"
    assert trace.trace_id_source.kind == :external_alias
    assert trace.created_at == nil
    assert trace.created_at_wall_time == ~U[2026-04-10 10:00:00Z]
    assert trace.clock_domain.source == "citadel_trace_envelope"
    assert trace.metadata.lineage.trace_id == "trace-1"
    assert trace.metadata.lineage.tenant_id == "tenant-1"
    assert trace.metadata.lineage.causation_id == "req-1"
    assert trace.metadata.lineage.canonical_idempotency_key == "idem:v1:session-attached"
    assert trace.metadata.platform_envelope_field_map.trace_id == "AITrace.Trace.trace_id"

    assert trace.metadata.platform_envelope_field_map.request_id ==
             "AITrace.Context.metadata.causation_id"

    assert [%Span{name: "citadel.event", events: [event]}] = trace.spans
    assert hd(trace.spans).span_id_source.kind == :external_alias
    assert hd(trace.spans).start_time == nil
    assert hd(trace.spans).start_wall_time == ~U[2026-04-10 10:00:00Z]
    assert hd(trace.spans).clock_domain.source == "citadel_trace_envelope"
    assert event.name == "citadel.session.attached"
    assert event.timestamp == nil
    assert event.wall_time == ~U[2026-04-10 10:00:00Z]
    assert event.clock_domain.source == "citadel_trace_envelope"
    assert event.attributes["attach_mode"] == "fresh_or_reuse"
  end

  test "translates completed spans without inventing an open-span API" do
    envelope =
      TraceEnvelope.new!(%{
        trace_envelope_id: "env-2",
        record_kind: :span,
        family: "decision_task",
        name: "citadel.span.decision_task",
        phase: "post_commit",
        trace_id: "trace-2",
        tenant_id: "tenant-1",
        session_id: "sess-1",
        request_id: "req-1",
        decision_id: "dec-1",
        snapshot_seq: 1,
        signal_id: nil,
        outbox_entry_id: nil,
        boundary_ref: nil,
        span_id: "span-1",
        parent_span_id: "parent-span-1",
        occurred_at: nil,
        started_at: ~U[2026-04-10 10:00:00Z],
        finished_at: ~U[2026-04-10 10:00:01Z],
        status: "ok",
        attributes: %{"duration_bucket" => "fast"},
        extensions: %{"canonical_idempotency_key" => "idem:v1:decision-task"}
      })

    assert :ok = TraceBridge.publish_trace(envelope, trace_bridge_opts())
    assert_receive {:exported_trace, trace}

    assert [
             %Span{
               name: "citadel.span.decision_task",
               span_id: "span-1",
               span_id_source: %{kind: :external_alias},
               parent_span_id: "parent-span-1",
               parent_span_id_source: %{kind: :external_alias},
               start_time: nil,
               end_time: nil,
               start_wall_time: ~U[2026-04-10 10:00:00Z],
               end_wall_time: ~U[2026-04-10 10:00:01Z]
             }
           ] = trace.spans

    assert trace.metadata.aitrace_context.trace_id == "trace-2"
    assert trace.metadata.aitrace_context.span_id == "span-1"
    assert trace.metadata.platform_envelope_field_map.span_id == "AITrace.Context.span_id"
  end

  test "bounds AITrace event attributes after adding correlation fields" do
    profile = CardinalityBounds.profile!(:trace_event)

    user_attributes =
      Enum.into(1..profile.max_attributes_per_span, %{}, fn index ->
        {"z_user_attr_#{index}", index}
      end)

    envelope =
      TraceEnvelope.new!(%{
        trace_envelope_id: "env-cardinality",
        record_kind: :event,
        family: "session_attached",
        name: "citadel.session.attached",
        phase: "post_commit",
        trace_id: "trace-cardinality",
        tenant_id: "tenant-1",
        session_id: "sess-1",
        request_id: "req-1",
        decision_id: "dec-1",
        snapshot_seq: 1,
        signal_id: "sig-1",
        outbox_entry_id: "outbox-1",
        boundary_ref: "boundary-ref-1",
        span_id: nil,
        parent_span_id: nil,
        occurred_at: ~U[2026-04-10 10:00:00Z],
        started_at: nil,
        finished_at: nil,
        status: "ok",
        attributes: user_attributes,
        extensions: %{}
      })

    assert :ok = TraceBridge.publish_trace(envelope, trace_bridge_opts())
    assert_receive {:exported_trace, trace}

    assert [%Span{events: [event]}] = trace.spans
    assert map_size(event.attributes) == profile.max_attributes_per_span
    assert event.attributes["family"] == "session_attached"
    assert event.attributes["request_id"] == "req-1"
    assert event.attributes["tenant_id"] == "tenant-1"

    assert %{
             "artifact_kind" => "trace_attribute_overflow_summary",
             "overflow_reasons" => overflow_reasons,
             "spillover_count" => spillover_count
           } = Map.fetch!(event.attributes, TraceEnvelope.trace_attribute_overflow_key())

    assert "attribute_count" in overflow_reasons
    assert spillover_count > 0
  end

  test "returns stable invalid_envelope errors for malformed payloads" do
    assert {:error, :invalid_envelope} =
             TraceBridge.publish_trace(
               %{
                 trace_envelope_id: "env-3",
                 record_kind: :event,
                 family: "session_attached",
                 name: "citadel.session.attached",
                 phase: "post_commit",
                 trace_id: "trace-3",
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
                 occurred_at: nil,
                 started_at: nil,
                 finished_at: nil,
                 status: "ok",
                 attributes: %{},
                 extensions: %{}
               },
               trace_bridge_opts()
             )
  end

  test "uses explicit trace exporters instead of ambient application env" do
    previous_exporters = Application.get_env(:aitrace, :exporters)
    previous_adapter = Application.get_env(:citadel_trace_bridge, :adapter)

    Application.put_env(:aitrace, :exporters, [{AmbientExporter, test_pid: self()}])
    Application.put_env(:citadel_trace_bridge, :adapter, AmbientAdapter)

    on_exit(fn ->
      restore_app_env(:aitrace, :exporters, previous_exporters)
      restore_app_env(:citadel_trace_bridge, :adapter, previous_adapter)
    end)

    assert :ok =
             TraceBridge.publish_trace(trace_envelope_fixture("env-ambient"), trace_bridge_opts())

    assert_receive {:exported_trace, trace}
    assert trace.trace_id == "trace-env-ambient"
    refute_received {:ambient_exported_trace, _trace}
    refute_received {:ambient_adapter_trace, _envelope}
  end

  defp trace_bridge_opts do
    [legacy_exporters: [{TestExporter, test_pid: self()}]]
  end

  defp restore_app_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_app_env(app, key, value), do: Application.put_env(app, key, value)

  defp trace_envelope_fixture(id) do
    TraceEnvelope.new!(%{
      trace_envelope_id: id,
      record_kind: :event,
      family: "session_attached",
      name: "citadel.session.attached",
      phase: "post_commit",
      trace_id: "trace-#{id}",
      tenant_id: "tenant-1",
      session_id: "sess-1",
      request_id: "req-1",
      decision_id: "dec-1",
      snapshot_seq: 1,
      signal_id: nil,
      outbox_entry_id: nil,
      boundary_ref: "boundary-ref-1",
      span_id: nil,
      parent_span_id: nil,
      occurred_at: ~U[2026-04-10 10:00:00Z],
      started_at: nil,
      finished_at: nil,
      status: "ok",
      attributes: %{"attach_mode" => "fresh_or_reuse"},
      extensions: %{"canonical_idempotency_key" => "idem:v1:session-attached"}
    })
  end
end
