defmodule Citadel.Kernel.TracePublisherTest do
  use ExUnit.Case, async: false

  alias Citadel.ObservabilityContract.Telemetry
  alias Citadel.ObservabilityContract.Trace, as: TraceContract
  alias Citadel.TraceEnvelope
  alias Citadel.Kernel.TracePublisher

  defmodule TelemetryForwarder do
    def handle_event(event, measurements, metadata, test_pid) do
      send(test_pid, {:telemetry, event, measurements, metadata})
    end
  end

  defmodule NoopTracePort do
    @behaviour Citadel.Ports.Trace

    @impl true
    def publish_trace(_envelope), do: :ok

    @impl true
    def publish_traces(_envelopes), do: :ok
  end

  defmodule FailingTracePort do
    @behaviour Citadel.Ports.Trace

    @impl true
    def publish_trace(_envelope), do: {:error, :unavailable}

    @impl true
    def publish_traces(_envelopes), do: {:error, :unavailable}
  end

  test "buffer overflow preserves the protected error-family evidence window and emits dropped-family telemetry" do
    attach_telemetry(self())
    drop_event = Telemetry.event_name(:trace_publication_drop)
    depth_event = Telemetry.event_name(:trace_buffer_depth)

    publisher =
      start_trace_publisher(
        trace_port: NoopTracePort,
        buffer_capacity: 4,
        protected_error_capacity: 2,
        flush_interval_ms: 1_000,
        batch_size: 4
      )

    assert :ok =
             TracePublisher.publish_trace(
               publisher,
               regular_envelope("env-1", "session_attached")
             )

    assert :ok =
             TracePublisher.publish_trace(
               publisher,
               regular_envelope("env-2", "signal_normalized")
             )

    assert :ok =
             TracePublisher.publish_trace(
               publisher,
               protected_envelope("env-3", "session_blocked")
             )

    assert :ok =
             TracePublisher.publish_trace(
               publisher,
               protected_envelope("env-4", "session_crash_recovery_triggered")
             )

    assert :ok =
             TracePublisher.publish_trace(publisher, regular_envelope("env-5", "session_resumed"))

    assert TracePublisher.snapshot(publisher) == %{depth: 4, protected_depth: 2, regular_depth: 2}

    assert_receive {:telemetry, ^drop_event, %{count: 1},
                    %{
                      dropped_family: "session_attached",
                      dropped_family_classification: :default,
                      trace_id: "trace-1",
                      tenant_id: "tenant-1",
                      request_id: "req-1",
                      decision_id: nil,
                      boundary_ref: "boundary-ref-1",
                      trace_envelope_id: "env-1"
                    }}

    assert_receive {:telemetry, ^depth_event, %{depth: 4, protected_depth: 2, regular_depth: 2},
                    %{}}

    assert_contract_shape(:trace_publication_drop, %{count: 1}, %{
      dropped_family: "session_attached",
      dropped_family_classification: :default,
      trace_id: "trace-1",
      tenant_id: "tenant-1",
      request_id: "req-1",
      decision_id: nil,
      boundary_ref: "boundary-ref-1",
      trace_envelope_id: "env-1"
    })

    assert_contract_shape(
      :trace_buffer_depth,
      %{depth: 4, protected_depth: 2, regular_depth: 2},
      %{}
    )
  end

  test "success output is rate-limited without evicting protected evidence" do
    attach_telemetry(self())
    drop_event = Telemetry.event_name(:trace_publication_drop)

    publisher =
      start_trace_publisher(
        trace_port: NoopTracePort,
        buffer_capacity: 2,
        protected_error_capacity: 2,
        flush_interval_ms: 1_000,
        batch_size: 2
      )

    assert :ok =
             TracePublisher.publish_trace(
               publisher,
               protected_envelope("env-protected-1", "session_blocked")
             )

    assert :ok =
             TracePublisher.publish_trace(
               publisher,
               protected_envelope("env-protected-2", "session_crash_recovery_triggered")
             )

    assert TracePublisher.snapshot(publisher) == %{depth: 2, protected_depth: 2, regular_depth: 0}

    assert :ok =
             TracePublisher.publish_trace(
               publisher,
               regular_envelope("env-success", "session_attached")
             )

    assert TracePublisher.snapshot(publisher) == %{depth: 2, protected_depth: 2, regular_depth: 0}

    assert_receive {:telemetry, ^drop_event, %{count: 1},
                    %{
                      dropped_family: "session_attached",
                      dropped_family_classification: :default,
                      trace_envelope_id: "env-success"
                    }}
  end

  test "debug output is dropped by the sampling policy" do
    attach_telemetry(self())
    drop_event = Telemetry.event_name(:trace_publication_drop)

    publisher =
      start_trace_publisher(
        trace_port: NoopTracePort,
        buffer_capacity: 4,
        protected_error_capacity: 2,
        flush_interval_ms: 1_000,
        batch_size: 4
      )

    assert :ok =
             TracePublisher.publish_trace(
               publisher,
               debug_envelope("env-debug", "session_attached")
             )

    assert TracePublisher.snapshot(publisher) == %{depth: 0, protected_depth: 0, regular_depth: 0}

    assert_receive {:telemetry, ^drop_event, %{count: 1},
                    %{
                      dropped_family: "session_attached",
                      dropped_family_classification: :default,
                      trace_envelope_id: "env-debug"
                    }}
  end

  test "success output obeys the declared sample rate budget" do
    attach_telemetry(self())
    drop_event = Telemetry.event_name(:trace_publication_drop)

    publisher =
      start_trace_publisher(
        trace_port: NoopTracePort,
        buffer_capacity: 4,
        protected_error_capacity: 1,
        sample_rate_or_budget: "success=2/min;debug=drop;protected=always",
        flush_interval_ms: 1_000,
        batch_size: 4
      )

    assert :ok =
             TracePublisher.publish_trace(
               publisher,
               regular_envelope("env-success-1", "session_attached")
             )

    assert :ok =
             TracePublisher.publish_trace(
               publisher,
               regular_envelope("env-success-2", "signal_normalized")
             )

    assert :ok =
             TracePublisher.publish_trace(
               publisher,
               regular_envelope("env-success-3", "session_resumed")
             )

    assert :ok =
             TracePublisher.publish_trace(
               publisher,
               protected_envelope("env-protected", "session_blocked")
             )

    assert TracePublisher.snapshot(publisher) == %{depth: 3, protected_depth: 1, regular_depth: 2}

    assert_receive {:telemetry, ^drop_event, %{count: 1},
                    %{
                      dropped_family: "session_resumed",
                      dropped_family_classification: :default,
                      trace_envelope_id: "env-success-3"
                    }}
  end

  test "buffer requires a sampling policy for success debug and protected evidence" do
    assert_raise ArgumentError, fn ->
      TracePublisher.Buffer.new!(
        total_capacity: 2,
        protected_capacity: 1,
        sample_rate_or_budget: "success=10/min;protected=always"
      )
    end

    assert_raise ArgumentError, fn ->
      TracePublisher.Buffer.new!(
        total_capacity: 2,
        protected_capacity: 1,
        sample_rate_or_budget: "success=10/min;debug=drop"
      )
    end

    assert_raise ArgumentError, fn ->
      TracePublisher.Buffer.new!(
        total_capacity: 2,
        protected_capacity: 1,
        sample_policy: :unbounded_success
      )
    end
  end

  test "publication failures emit low-cardinality telemetry without blocking the caller" do
    attach_telemetry(self())
    failure_event = Telemetry.event_name(:trace_publication_failure)

    publisher =
      start_trace_publisher(
        trace_port: FailingTracePort,
        buffer_capacity: 2,
        protected_error_capacity: 1,
        flush_interval_ms: 0,
        batch_size: 1
      )

    assert :ok =
             TracePublisher.publish_trace(
               publisher,
               regular_envelope("env-fail", "session_attached")
             )

    assert_receive {:telemetry, ^failure_event, %{count: 1, batch_size: 1},
                    %{
                      reason_code: :unavailable,
                      trace_id: "trace-1",
                      tenant_id: "tenant-1",
                      request_id: "req-1",
                      decision_id: nil,
                      boundary_ref: "boundary-ref-1",
                      trace_envelope_id: "env-fail",
                      family: "session_attached"
                    }}

    assert_contract_shape(:trace_publication_failure, %{count: 1, batch_size: 1}, %{
      reason_code: :unavailable,
      trace_id: "trace-1",
      tenant_id: "tenant-1",
      request_id: "req-1",
      decision_id: nil,
      boundary_ref: "boundary-ref-1",
      trace_envelope_id: "env-fail",
      family: "session_attached"
    })
  end

  test "missing default trace backend emits failure telemetry without requiring aitrace" do
    attach_telemetry(self())
    failure_event = Telemetry.event_name(:trace_publication_failure)

    publisher =
      start_trace_publisher(
        buffer_capacity: 2,
        protected_error_capacity: 1,
        flush_interval_ms: 0,
        batch_size: 1
      )

    assert :ok =
             TracePublisher.publish_trace(
               publisher,
               regular_envelope("env-no-backend", "session_attached")
             )

    assert_receive {:telemetry, ^failure_event, %{count: 1, batch_size: 1},
                    %{
                      reason_code: :trace_backend_unavailable,
                      trace_envelope_id: "env-no-backend",
                      family: "session_attached"
                    }}

    assert Process.alive?(publisher)
  end

  defp start_trace_publisher(opts) do
    name = :"trace_publisher_#{System.unique_integer([:positive])}"
    start_supervised!({TracePublisher, Keyword.put(opts, :name, name)})
  end

  defp attach_telemetry(test_pid) do
    handler_id = "trace-publisher-test-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler_id,
      [
        Telemetry.event_name(:trace_buffer_depth),
        Telemetry.event_name(:trace_publication_drop),
        Telemetry.event_name(:trace_publication_failure)
      ],
      &TelemetryForwarder.handle_event/4,
      test_pid
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp regular_envelope(id, family) do
    TraceEnvelope.new!(%{
      trace_envelope_id: id,
      record_kind: :event,
      family: family,
      name: TraceContract.canonical_event_name!(family),
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
      attributes: %{},
      extensions: %{}
    })
  end

  defp debug_envelope(id, family) do
    id
    |> regular_envelope(family)
    |> Map.put(:phase, "debug")
  end

  defp protected_envelope(id, family) do
    regular_envelope(id, family)
  end

  defp assert_contract_shape(telemetry_name, measurements, metadata) do
    assert Enum.sort(Map.keys(measurements)) ==
             telemetry_name |> Telemetry.measurement_keys() |> Enum.sort()

    assert Enum.sort(Map.keys(metadata)) ==
             telemetry_name |> Telemetry.metadata_keys() |> Enum.sort()
  end
end
