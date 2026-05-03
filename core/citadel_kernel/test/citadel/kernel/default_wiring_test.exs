defmodule Citadel.Kernel.DefaultWiringTest do
  use ExUnit.Case, async: false

  alias Citadel.ObservabilityContract.Telemetry
  alias Citadel.Kernel
  alias Citadel.Kernel.BoundaryLeaseTracker
  alias Citadel.Kernel.KernelSnapshot
  alias Citadel.Kernel.ServiceCatalog
  alias Citadel.Kernel.SessionDirectory
  alias Citadel.Kernel.SignalIngress

  defmodule TestSignalSource do
    @behaviour Citadel.Ports.SignalSource

    @impl true
    def normalize_signal(observation), do: {:ok, observation}
  end

  defmodule TelemetryForwarder do
    def handle_event(event_name, measurements, metadata, test_pid) do
      send(test_pid, {:telemetry_event, event_name, measurements, metadata})
    end
  end

  test "start_session wires the default trace publisher" do
    handler_id = "runtime-default-wiring-#{System.unique_integer([:positive])}"
    kernel_snapshot = unique_name(:kernel_snapshot)
    session_directory = unique_name(:session_directory)
    service_catalog = unique_name(:service_catalog)
    boundary_tracker = unique_name(:boundary_tracker)
    signal_ingress = unique_name(:signal_ingress)
    invocation_supervisor = unique_name(:invocation_supervisor)
    projection_supervisor = unique_name(:projection_supervisor)
    local_supervisor = unique_name(:local_supervisor)
    session_id = "sess-runtime-trace"

    :ok =
      :telemetry.attach(
        handler_id,
        Telemetry.event_name(:trace_buffer_depth),
        &TelemetryForwarder.handle_event/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    start_supervised!({KernelSnapshot, name: kernel_snapshot})

    start_supervised!(
      {SessionDirectory, name: session_directory, kernel_snapshot: kernel_snapshot}
    )

    start_supervised!({ServiceCatalog, name: service_catalog, kernel_snapshot: kernel_snapshot})

    start_supervised!(
      {BoundaryLeaseTracker, name: boundary_tracker, kernel_snapshot: kernel_snapshot}
    )

    start_supervised!({Task.Supervisor, name: invocation_supervisor})
    start_supervised!({Task.Supervisor, name: projection_supervisor})
    start_supervised!({Task.Supervisor, name: local_supervisor})

    start_supervised!(
      {SignalIngress,
       name: signal_ingress,
       session_directory: session_directory,
       signal_source: TestSignalSource,
       auto_rebuild?: false}
    )

    assert {:ok, _pid} =
             Kernel.start_session(
               session_id: session_id,
               session_directory: session_directory,
               kernel_snapshot: kernel_snapshot,
               boundary_lease_tracker: boundary_tracker,
               service_catalog: service_catalog,
               signal_ingress: signal_ingress,
               invocation_supervisor: invocation_supervisor,
               projection_supervisor: projection_supervisor,
               local_supervisor: local_supervisor
             )

    assert {:ok, _session_server} = Kernel.lookup_session(session_id)

    trace_depth_event = Telemetry.event_name(:trace_buffer_depth)

    assert_receive {:telemetry_event, ^trace_depth_event,
                    %{
                      depth: depth,
                      protected_depth: protected_depth,
                      regular_depth: regular_depth
                    }, %{}}

    assert depth > 0
    assert protected_depth >= 0
    assert regular_depth >= 0
  end

  defp unique_name(prefix) do
    {:global, {__MODULE__, prefix, System.unique_integer([:positive])}}
  end
end
