defmodule Citadel.TraceBridge do
  @moduledoc """
  AITrace-facing trace publication bridge consuming canonical `Citadel.TraceEnvelope` values.
  """

  alias Citadel.ObservabilityContract.Trace, as: TraceContract
  alias Citadel.TraceEnvelope

  @behaviour Citadel.Ports.Trace

  @manifest %{
    package: :citadel_trace_bridge,
    layer: :bridge,
    status: :wave_5_contract_frozen,
    owns: [:trace_publication, :aitrace_translation, :stable_failure_codes],
    internal_dependencies: [:citadel_governance, :citadel_kernel, :citadel_observability_contract],
    external_dependencies: [:aitrace]
  }

  @type reason_code ::
          :unavailable
          | :timeout
          | :rate_limited
          | :invalid_envelope
          | :backend_rejected
          | :circuit_open
          | :unknown

  @impl true
  @spec publish_trace(TraceEnvelope.t()) :: :ok | {:error, reason_code()}
  def publish_trace(%TraceEnvelope{} = envelope) do
    publish_trace(envelope, [])
  end

  def publish_trace(_other), do: {:error, :invalid_envelope}

  @spec publish_trace(TraceEnvelope.t(), keyword()) :: :ok | {:error, reason_code()}
  def publish_trace(%TraceEnvelope{} = envelope, opts) when is_list(opts) do
    with {:ok, normalized_envelope} <- TraceEnvelope.new(envelope) do
      opts
      |> adapter()
      |> publish_one(normalized_envelope, adapter_opts(opts))
    else
      {:error, _error} -> {:error, :invalid_envelope}
    end
  end

  def publish_trace(_other, _opts), do: {:error, :invalid_envelope}

  @impl true
  @spec publish_traces([TraceEnvelope.t()]) :: :ok | {:error, reason_code()}
  def publish_traces(envelopes) when is_list(envelopes) do
    publish_traces(envelopes, [])
  end

  def publish_traces(_other), do: {:error, :invalid_envelope}

  @spec publish_traces([TraceEnvelope.t()], keyword()) :: :ok | {:error, reason_code()}
  def publish_traces(envelopes, opts) when is_list(envelopes) and is_list(opts) do
    with {:ok, normalized_envelopes} <- normalize_envelopes(envelopes) do
      opts
      |> adapter()
      |> publish_many(normalized_envelopes, adapter_opts(opts))
    end
  end

  def publish_traces(_other, _opts), do: {:error, :invalid_envelope}

  @spec export_targets() :: [atom()]
  def export_targets, do: [:aitrace]

  @spec failure_reason_codes() :: [atom(), ...]
  def failure_reason_codes, do: TraceContract.failure_reason_codes()

  @spec manifest() :: map()
  def manifest, do: @manifest

  defp adapter(opts) do
    Keyword.get(opts, :adapter, Citadel.TraceBridge.AITraceAdapter)
  end

  defp adapter_opts(opts) do
    opts
    |> Keyword.delete(:adapter)
    |> Keyword.put_new(:legacy_exporters, [])
  end

  defp publish_one(adapter, envelope, opts) do
    Code.ensure_loaded(adapter)

    cond do
      function_exported?(adapter, :publish_trace, 2) -> adapter.publish_trace(envelope, opts)
      function_exported?(adapter, :publish_trace, 1) -> adapter.publish_trace(envelope)
      true -> {:error, :unavailable}
    end
  end

  defp publish_many(adapter, envelopes, opts) do
    Code.ensure_loaded(adapter)

    cond do
      function_exported?(adapter, :publish_traces, 2) ->
        adapter.publish_traces(envelopes, opts)

      function_exported?(adapter, :publish_traces, 1) ->
        adapter.publish_traces(envelopes)

      true ->
        Enum.reduce_while(envelopes, :ok, fn envelope, :ok ->
          case publish_one(adapter, envelope, opts) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
    end
  end

  defp normalize_envelopes(envelopes) do
    Enum.reduce_while(envelopes, {:ok, []}, fn
      %TraceEnvelope{} = envelope, {:ok, acc} ->
        case TraceEnvelope.new(envelope) do
          {:ok, normalized_envelope} ->
            {:cont, {:ok, [normalized_envelope | acc]}}

          {:error, _error} ->
            {:halt, {:error, :invalid_envelope}}
        end

      _other, _acc ->
        {:halt, {:error, :invalid_envelope}}
    end)
    |> case do
      {:ok, normalized_envelopes} -> {:ok, Enum.reverse(normalized_envelopes)}
      {:error, :invalid_envelope} = error -> error
    end
  end
end
