defmodule Citadel.Kernel.ObservationSignalSourceTest do
  use ExUnit.Case, async: true

  alias Citadel.Kernel.ObservationSignalSource
  alias Citadel.Kernel.SignalIngress
  alias Citadel.RuntimeObservation

  test "accepts normalized observations and rejects ambiguous raw maps" do
    observation = runtime_observation("sess-1", "signal-1")

    assert {:ok, ^observation} = ObservationSignalSource.normalize_signal(observation)

    assert {:error, :runtime_observation_required} =
             ObservationSignalSource.normalize_signal(%{
               session_id: "sess-1",
               signal_id: "signal-1",
               payload: %{}
             })
  end

  test "deliver_observation routes a normalized observation through signal ingress" do
    {:ok, server} =
      SignalIngress.start_link(
        name: unique_name(:signal_ingress),
        signal_source: ObservationSignalSource
      )

    assert :ok = SignalIngress.register_subscription(server, "sess-1")

    observation = runtime_observation("sess-1", "signal-1")
    assert {:ok, %{async_handoff?: true}} = SignalIngress.deliver_observation(server, observation)

    assert %{transport_cursor: "cursor/signal-1"} =
             SignalIngress.subscription_state(server, "sess-1")
  end

  defp runtime_observation(session_id, signal_id) do
    RuntimeObservation.new!(%{
      observation_id: "obs/#{signal_id}",
      request_id: "req/#{signal_id}",
      session_id: session_id,
      signal_id: signal_id,
      signal_cursor: "cursor/#{signal_id}",
      runtime_ref_id: "runtime/#{session_id}",
      event_kind: "host_signal",
      event_at: ~U[2026-04-10 10:00:00Z],
      status: "ok",
      output: %{},
      artifacts: [],
      payload: %{"status" => "ok"},
      subject_ref: %{kind: :run, id: session_id, metadata: %{}},
      evidence_refs: [],
      governance_refs: [],
      extensions: %{
        "tenant_id" => "tenant-1",
        "authority_scope" => "authority-1",
        "trace_id" => "trace/#{signal_id}",
        "causation_id" => "cause/#{signal_id}",
        "canonical_idempotency_key" => "idem:v1:#{signal_id}"
      }
    })
  end

  defp unique_name(prefix),
    do: {:global, {__MODULE__, prefix, System.unique_integer([:positive])}}
end
