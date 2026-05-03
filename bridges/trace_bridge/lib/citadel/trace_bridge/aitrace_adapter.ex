defmodule Citadel.TraceBridge.AITraceAdapter do
  @moduledoc false

  alias AITrace.{Context, Event, Span, Trace}
  alias Citadel.TraceEnvelope

  @spec publish_trace(TraceEnvelope.t()) :: :ok | {:error, atom()}
  def publish_trace(%TraceEnvelope{} = envelope) do
    envelope
    |> to_trace()
    |> export_trace()
    |> normalize_export_result()
  end

  @spec publish_traces([TraceEnvelope.t()]) :: :ok | {:error, atom()}
  def publish_traces(envelopes) when is_list(envelopes) do
    Enum.reduce_while(envelopes, :ok, fn envelope, :ok ->
      case publish_trace(envelope) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp to_trace(%TraceEnvelope{record_kind: :event} = envelope) do
    span_id = envelope.span_id || synthetic_span_id("event-span", envelope)

    event =
      Event
      |> struct!(%{
        name: envelope.name,
        timestamp: nil,
        attributes: event_attributes(envelope)
      })
      |> put_supported_field(:wall_time, envelope.occurred_at)
      |> put_supported_field(:clock_domain, imported_clock_domain(envelope))

    synthetic_span =
      imported_span(envelope,
        span_id: span_id,
        name: "citadel.event",
        start_wall_time: envelope.occurred_at,
        end_wall_time: envelope.occurred_at,
        attributes:
          TraceEnvelope.bound_trace_attributes!(
            %{
              "family" => envelope.family,
              "phase" => envelope.phase,
              "record_kind" => "event"
            },
            :trace_span,
            label: "Citadel.TraceBridge.synthetic_event_span.attributes"
          ),
        events: bounded_span_events([event])
      )

    imported_trace(envelope, envelope.occurred_at, [synthetic_span])
  end

  defp to_trace(%TraceEnvelope{record_kind: :span} = envelope) do
    span_id = envelope.span_id || synthetic_span_id("span", envelope)

    span =
      imported_span(envelope,
        span_id: span_id,
        name: envelope.name,
        start_wall_time: envelope.started_at,
        end_wall_time: envelope.finished_at,
        attributes: span_attributes(envelope),
        events: []
      )

    imported_trace(envelope, envelope.started_at, [span])
  end

  defp imported_trace(%TraceEnvelope{} = envelope, created_at_wall_time, spans) do
    context =
      envelope.trace_id
      |> Context.new()
      |> Context.with_span_id(primary_span_id(spans))

    trace_id_source = trace_id_source(envelope.trace_id, context)

    Trace
    |> struct!(%{
      trace_id: envelope.trace_id,
      created_at: nil,
      spans: spans,
      metadata: trace_metadata(envelope, context, trace_id_source)
    })
    |> put_supported_field(:trace_id_source, trace_id_source)
    |> put_supported_field(:created_at_wall_time, created_at_wall_time)
    |> put_supported_field(:clock_domain, imported_clock_domain(envelope))
  end

  defp imported_span(%TraceEnvelope{} = envelope, opts) do
    span_id = Keyword.fetch!(opts, :span_id)

    Span
    |> struct!(%{
      span_id: span_id,
      parent_span_id: envelope.parent_span_id,
      name: Keyword.fetch!(opts, :name),
      start_time: nil,
      end_time: nil,
      attributes: Keyword.fetch!(opts, :attributes),
      events: Keyword.fetch!(opts, :events),
      status: span_status(envelope.status)
    })
    |> put_supported_field(:span_id_source, id_source!(:span, span_id, :external_alias))
    |> put_supported_field(:parent_span_id_source, parent_span_id_source(envelope.parent_span_id))
    |> put_supported_field(:start_wall_time, Keyword.fetch!(opts, :start_wall_time))
    |> put_supported_field(:end_wall_time, Keyword.fetch!(opts, :end_wall_time))
    |> put_supported_field(:clock_domain, imported_clock_domain(envelope))
  end

  defp trace_metadata(%TraceEnvelope{} = envelope, %Context{} = context, trace_id_source) do
    %{
      family: envelope.family,
      phase: envelope.phase,
      record_kind: Atom.to_string(envelope.record_kind),
      trace_envelope_id: envelope.trace_envelope_id,
      tenant_id: envelope.tenant_id,
      session_id: envelope.session_id,
      request_id: envelope.request_id,
      decision_id: envelope.decision_id,
      snapshot_seq: envelope.snapshot_seq,
      signal_id: envelope.signal_id,
      outbox_entry_id: envelope.outbox_entry_id,
      boundary_ref: envelope.boundary_ref,
      lineage: lineage_metadata(envelope),
      aitrace_context: %{
        trace_id: context.trace_id,
        trace_id_source: trace_id_source,
        span_id: context.span_id
      },
      platform_envelope_field_map: platform_envelope_field_map()
    }
    |> Map.merge(envelope.extensions)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp event_attributes(%TraceEnvelope{} = envelope) do
    base =
      %{
        "family" => envelope.family,
        "phase" => envelope.phase,
        "status" => envelope.status,
        "tenant_id" => envelope.tenant_id,
        "session_id" => envelope.session_id,
        "request_id" => envelope.request_id,
        "decision_id" => envelope.decision_id,
        "snapshot_seq" => envelope.snapshot_seq,
        "signal_id" => envelope.signal_id,
        "outbox_entry_id" => envelope.outbox_entry_id,
        "boundary_ref" => envelope.boundary_ref
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    envelope.attributes
    |> Map.merge(base)
    |> TraceEnvelope.bound_trace_attributes!(:trace_event,
      label: "Citadel.TraceBridge.event.attributes"
    )
  end

  defp span_attributes(%TraceEnvelope{} = envelope) do
    base =
      %{
        "family" => envelope.family,
        "phase" => envelope.phase,
        "tenant_id" => envelope.tenant_id,
        "session_id" => envelope.session_id,
        "request_id" => envelope.request_id,
        "decision_id" => envelope.decision_id,
        "snapshot_seq" => envelope.snapshot_seq,
        "signal_id" => envelope.signal_id,
        "outbox_entry_id" => envelope.outbox_entry_id,
        "boundary_ref" => envelope.boundary_ref
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    envelope.attributes
    |> Map.merge(base)
    |> TraceEnvelope.bound_trace_attributes!(:trace_span,
      label: "Citadel.TraceBridge.span.attributes"
    )
  end

  defp bounded_span_events(events) when is_list(events) do
    profile = Citadel.ObservabilityContract.CardinalityBounds.profile!(:trace_event)
    Enum.take(events, profile.max_events_per_span)
  end

  defp parent_span_id_source(nil), do: nil

  defp parent_span_id_source(parent_span_id) do
    if identifier_function_exported?(:parent_span_source!, 1) do
      apply(AITrace.Identifier, :parent_span_source!, [parent_span_id])
    else
      source_kind =
        if generated_id?(parent_span_id),
          do: :aitrace_generated,
          else: :external_alias

      id_source!(:span, parent_span_id, source_kind)
    end
  end

  defp trace_id_source(trace_id, %Context{} = context) do
    Map.get(context, :trace_id_source) || id_source!(:trace, trace_id, :external_alias)
  end

  defp id_source!(id_type, id, source_kind) do
    if identifier_function_exported?(:source!, 3) do
      apply(AITrace.Identifier, :source!, [id_type, id, source_kind])
    else
      fallback_id_source!(id_type, id, source_kind)
    end
  end

  defp identifier_function_exported?(function, arity) do
    Code.ensure_loaded?(AITrace.Identifier) and
      function_exported?(AITrace.Identifier, function, arity)
  end

  defp fallback_id_source!(id_type, id, :aitrace_generated) when id_type in [:trace, :span] do
    if generated_id?(id) do
      %{
        id_type: id_type,
        kind: :aitrace_generated,
        policy: "aitrace-id-v1",
        algorithm: "crypto.strong_rand_bytes",
        entropy_bytes: 16,
        encoding: "base16_lower",
        prefix: nil,
        prefix_policy: "none_backcompat_32_hex"
      }
    else
      raise ArgumentError,
            "invalid AITrace-generated #{id_type} id: expected 32 lowercase hex characters"
    end
  end

  defp fallback_id_source!(id_type, id, :external_alias) when id_type in [:trace, :span] do
    if external_alias?(id) do
      %{
        id_type: id_type,
        kind: :external_alias,
        policy: "aitrace-external-alias-v1",
        validation: "bounded_external_alias",
        max_bytes: 128
      }
    else
      raise ArgumentError,
            "invalid external #{id_type} alias: expected 1-128 chars of [A-Za-z0-9._:-] starting with alnum"
    end
  end

  defp put_supported_field(struct, field, value) do
    if Map.has_key?(struct, field) do
      Map.put(struct, field, value)
    else
      struct
    end
  end

  defp synthetic_span_id(prefix, %TraceEnvelope{} = envelope) do
    "#{prefix}:#{envelope.trace_envelope_id}"
  end

  defp primary_span_id([%Span{span_id: span_id} | _rest]), do: span_id

  defp imported_clock_domain(%TraceEnvelope{} = envelope) do
    %{
      source: "citadel_trace_envelope",
      trace_envelope_id: envelope.trace_envelope_id,
      wall_time_source: "Citadel.TraceEnvelope",
      monotonic_unit: nil
    }
  end

  defp lineage_metadata(%TraceEnvelope{} = envelope) do
    %{
      trace_id: envelope.trace_id,
      tenant_id: envelope.tenant_id,
      causation_id: envelope.request_id,
      canonical_idempotency_key: canonical_idempotency_key(envelope),
      authority_ref: envelope.decision_id,
      boundary_ref: envelope.boundary_ref,
      source_position: source_position(envelope)
    }
    |> Enum.reject(fn {_key, value} -> empty_lineage_value?(value) end)
    |> Map.new()
  end

  defp canonical_idempotency_key(%TraceEnvelope{} = envelope) do
    Map.get(envelope.extensions, "canonical_idempotency_key") ||
      Map.get(envelope.extensions, "idempotency_key")
  end

  defp source_position(%TraceEnvelope{} = envelope) do
    %{
      snapshot_seq: envelope.snapshot_seq,
      signal_id: envelope.signal_id,
      outbox_entry_id: envelope.outbox_entry_id
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp empty_lineage_value?(nil), do: true
  defp empty_lineage_value?(value) when is_map(value), do: map_size(value) == 0
  defp empty_lineage_value?(_value), do: false

  defp platform_envelope_field_map do
    %{
      trace_id: "AITrace.Trace.trace_id",
      tenant_id: "AITrace.Trace.metadata.lineage.tenant_id",
      request_id: "AITrace.Context.metadata.causation_id",
      decision_id: "AITrace.Trace.metadata.lineage.authority_ref",
      span_id: "AITrace.Context.span_id",
      parent_span_id: "AITrace.Span.parent_span_id",
      occurred_at: "AITrace.Event.wall_time",
      started_at: "AITrace.Span.start_wall_time",
      finished_at: "AITrace.Span.end_wall_time",
      snapshot_seq: "AITrace.Trace.metadata.lineage.source_position.snapshot_seq"
    }
  end

  defp export_trace(%Trace{} = trace) do
    if function_exported?(AITrace, :export, 1) do
      apply(AITrace, :export, [trace])
    else
      legacy_export_trace(trace)
    end
  end

  defp legacy_export_trace(%Trace{} = trace) do
    exporters = Application.get_env(:aitrace, :exporters, []) || []

    if exporters == [] do
      {:error, :unavailable}
    else
      Enum.reduce_while(exporters, :ok, fn exporter_config, :ok ->
        with {:ok, exporter_module, opts} <- normalize_exporter(exporter_config),
             {:ok, state} <- normalize_result(exporter_module.init(opts)),
             {:ok, next_state} <- normalize_result(exporter_module.export(trace, state)) do
          maybe_shutdown(exporter_module, next_state)
          {:cont, :ok}
        else
          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp normalize_export_result(:ok), do: :ok
  defp normalize_export_result({:error, reason}), do: {:error, map_error_reason(reason)}

  defp normalize_exporter({exporter_module, opts}) when is_atom(exporter_module) do
    {:ok, exporter_module, Map.new(opts)}
  end

  defp normalize_exporter(exporter_module) when is_atom(exporter_module) do
    {:ok, exporter_module, %{}}
  end

  defp normalize_exporter(_other), do: {:error, :backend_rejected}

  defp normalize_result({:ok, state}), do: {:ok, state}
  defp normalize_result({:error, reason}), do: {:error, reason}
  defp normalize_result(_other), do: {:error, :backend_rejected}

  defp maybe_shutdown(module, state) do
    if function_exported?(module, :shutdown, 1) do
      module.shutdown(state)
    end
  end

  defp span_status(nil), do: :ok
  defp span_status("ok"), do: :ok
  defp span_status("success"), do: :ok
  defp span_status(_status), do: :error

  defp map_error_reason(:invalid_exporter_config), do: :backend_rejected
  defp map_error_reason(:invalid_exporter_options), do: :backend_rejected
  defp map_error_reason(:timeout), do: :timeout
  defp map_error_reason(:rate_limited), do: :rate_limited
  defp map_error_reason(:backend_rejected), do: :backend_rejected
  defp map_error_reason(:unavailable), do: :unavailable
  defp map_error_reason(_other), do: :unknown

  defp generated_id?(id) do
    byte_size(id) == 32 and
      id
      |> :binary.bin_to_list()
      |> Enum.all?(&lower_hex?/1)
  end

  defp external_alias?(<<first, rest::binary>>) do
    byte_size(rest) <= 127 and alnum?(first) and
      rest
      |> :binary.bin_to_list()
      |> Enum.all?(fn byte -> alnum?(byte) or byte in [?., ?_, ?:, ?-] end)
  end

  defp external_alias?(_id), do: false

  defp lower_hex?(byte), do: byte in ?0..?9 or byte in ?a..?f

  defp alnum?(byte), do: byte in ?A..?Z or byte in ?a..?z or byte in ?0..?9
end
