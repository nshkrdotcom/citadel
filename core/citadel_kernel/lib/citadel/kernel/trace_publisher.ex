defmodule Citadel.Kernel.TracePublisher do
  @moduledoc """
  Best-effort bounded trace publisher used after commit.

  The runtime owns the process in the default application tree and session
  startup wires it by default through `Citadel.Kernel.start_session/1`.
  AITrace and the trace bridge remain optional backends; unavailable trace ports
  are reported as publication failures rather than runtime crashes.
  """

  use GenServer

  alias Citadel.ObservabilityContract.Telemetry
  alias Citadel.TraceEnvelope

  @unavailable_trace_backend_reason :trace_backend_unavailable

  defmodule SamplingPolicy do
    @moduledoc """
    Admission policy for success/debug trace output.

    Protected error or non-success evidence is never admitted through the
    success/debug budget; the segmented buffer owns the bounded incident
    evidence window for those records.
    """

    alias Citadel.ObservabilityContract.CardinalityBounds
    alias Citadel.TraceEnvelope

    @protected_statuses ~w(blocked denied error fail_closed failed failure quarantined rejected)
    @debug_markers ~w(debug diagnostic diagnostics trace verbose)

    @type admission :: :protected | :regular | :drop_debug
    @type t :: %__MODULE__{
            sample_policy: atom(),
            sample_rate_or_budget: String.t(),
            success_budget_per_minute: pos_integer(),
            debug_action: :drop,
            protected_action: :always
          }

    @enforce_keys [
      :sample_policy,
      :sample_rate_or_budget,
      :success_budget_per_minute,
      :debug_action,
      :protected_action
    ]
    defstruct @enforce_keys

    @spec new!(keyword()) :: t()
    def new!(opts \\ []) do
      profile = Keyword.get(opts, :profile, CardinalityBounds.profile!(:trace_event))
      sample_policy = Keyword.get(opts, :sample_policy, profile.sample_policy)

      sample_rate_or_budget =
        Keyword.get(opts, :sample_rate_or_budget, profile.sample_rate_or_budget)

      budget = parse_rate_budget!(sample_rate_or_budget)

      ensure_sample_policy!(sample_policy)

      %__MODULE__{
        sample_policy: sample_policy,
        sample_rate_or_budget: sample_rate_or_budget,
        success_budget_per_minute: Map.fetch!(budget, :success_budget_per_minute),
        debug_action: Map.fetch!(budget, :debug_action),
        protected_action: Map.fetch!(budget, :protected_action)
      }
    end

    @spec classify(t(), TraceEnvelope.t()) :: admission()
    def classify(%__MODULE__{} = policy, %TraceEnvelope{} = envelope) do
      cond do
        protected_incident?(envelope) -> :protected
        debug_output?(envelope) and policy.debug_action == :drop -> :drop_debug
        true -> :regular
      end
    end

    defp ensure_sample_policy!(sample_policy) do
      if sample_policy in CardinalityBounds.sample_policies() do
        :ok
      else
        raise ArgumentError,
              "Citadel.Kernel.TracePublisher sample_policy is unsupported: " <>
                inspect(sample_policy)
      end
    end

    defp parse_rate_budget!(budget) when is_binary(budget) do
      entries =
        budget
        |> String.split(";", trim: true)
        |> Map.new(fn entry ->
          case String.split(entry, "=", parts: 2) do
            [key, value] -> {String.trim(key), String.trim(value)}
            _other -> raise invalid_budget_error(budget)
          end
        end)

      %{
        success_budget_per_minute: parse_success_budget!(Map.get(entries, "success"), budget),
        debug_action: parse_debug_action!(Map.get(entries, "debug"), budget),
        protected_action: parse_protected_action!(Map.get(entries, "protected"), budget)
      }
    end

    defp parse_rate_budget!(budget), do: raise(invalid_budget_error(budget))

    defp parse_success_budget!(nil, budget),
      do: raise(missing_budget_error(budget, "success=<positive>/min"))

    defp parse_success_budget!(value, budget) do
      case String.split(value, "/", parts: 2) do
        [count, unit] when unit in ["min", "minute"] ->
          case Integer.parse(count) do
            {integer, ""} when integer > 0 -> integer
            _other -> raise invalid_budget_error(budget)
          end

        _other ->
          raise invalid_budget_error(budget)
      end
    end

    defp parse_debug_action!(nil, budget), do: raise(missing_budget_error(budget, "debug=drop"))
    defp parse_debug_action!("drop", _budget), do: :drop
    defp parse_debug_action!(_value, budget), do: raise(invalid_budget_error(budget))

    defp parse_protected_action!(nil, budget),
      do: raise(missing_budget_error(budget, "protected=always"))

    defp parse_protected_action!("always", _budget), do: :always
    defp parse_protected_action!(_value, budget), do: raise(invalid_budget_error(budget))

    defp missing_budget_error(budget, required) do
      ArgumentError.exception(
        "Citadel.Kernel.TracePublisher sample_rate_or_budget must include #{required}, got: " <>
          inspect(budget)
      )
    end

    defp invalid_budget_error(budget) do
      ArgumentError.exception(
        "Citadel.Kernel.TracePublisher sample_rate_or_budget must match " <>
          "success=<positive>/min;debug=drop;protected=always, got: #{inspect(budget)}"
      )
    end

    defp protected_incident?(%TraceEnvelope{} = envelope) do
      TraceEnvelope.protected_error_family?(envelope) or protected_status?(envelope.status)
    end

    defp protected_status?(status) when is_binary(status) do
      String.downcase(status) in @protected_statuses
    end

    defp protected_status?(_status), do: false

    defp debug_output?(%TraceEnvelope{} = envelope) do
      debug_marker?(envelope.status) or debug_marker?(envelope.phase)
    end

    defp debug_marker?(value) when is_binary(value) do
      String.downcase(value) in @debug_markers
    end

    defp debug_marker?(_value), do: false
  end

  defmodule Buffer do
    @moduledoc """
    Segmented bounded buffer preserving a protected error-family evidence window.
    """

    alias Citadel.Kernel.TracePublisher.SamplingPolicy
    alias Citadel.TraceEnvelope

    @success_window_ms 60_000

    @type queued_envelope :: {non_neg_integer(), TraceEnvelope.t()}

    @type t :: %__MODULE__{
            total_capacity: pos_integer(),
            protected_capacity: non_neg_integer(),
            regular_capacity: non_neg_integer(),
            protected_queue: :queue.queue(queued_envelope()),
            regular_queue: :queue.queue(queued_envelope()),
            protected_len: non_neg_integer(),
            regular_len: non_neg_integer(),
            next_seq: non_neg_integer(),
            sampling_policy: SamplingPolicy.t(),
            success_window_started_ms: integer() | nil,
            success_window_count: non_neg_integer()
          }

    defstruct total_capacity: 0,
              protected_capacity: 0,
              regular_capacity: 0,
              protected_queue: :queue.new(),
              regular_queue: :queue.new(),
              protected_len: 0,
              regular_len: 0,
              next_seq: 0,
              sampling_policy: nil,
              success_window_started_ms: nil,
              success_window_count: 0

    @spec new!(keyword()) :: t()
    def new!(opts) do
      total_capacity = Keyword.get(opts, :total_capacity, 256)

      if total_capacity <= 0 do
        raise ArgumentError,
              "Citadel.Kernel.TracePublisher buffer total_capacity must be positive"
      end

      protected_capacity = min(Keyword.get(opts, :protected_capacity, 64), total_capacity)
      regular_capacity = total_capacity - protected_capacity

      if protected_capacity <= 0 do
        raise ArgumentError,
              "Citadel.Kernel.TracePublisher buffer protected_capacity must be positive"
      end

      %__MODULE__{
        total_capacity: total_capacity,
        protected_capacity: protected_capacity,
        regular_capacity: regular_capacity,
        protected_queue: :queue.new(),
        regular_queue: :queue.new(),
        protected_len: 0,
        regular_len: 0,
        next_seq: 0,
        sampling_policy:
          SamplingPolicy.new!(Keyword.take(opts, [:sample_policy, :sample_rate_or_budget])),
        success_window_started_ms: nil,
        success_window_count: 0
      }
    end

    @spec enqueue(t(), TraceEnvelope.t()) :: {t(), TraceEnvelope.t() | nil}
    def enqueue(%__MODULE__{} = buffer, %TraceEnvelope{} = envelope) do
      queued_envelope = {buffer.next_seq, envelope}

      case SamplingPolicy.classify(buffer.sampling_policy, envelope) do
        :protected -> do_enqueue(buffer, queued_envelope, :protected)
        :drop_debug -> {buffer, envelope}
        :regular -> maybe_enqueue_regular(buffer, queued_envelope)
      end
    end

    @spec take_batch(t(), pos_integer()) :: {[TraceEnvelope.t()], t()}
    def take_batch(%__MODULE__{} = buffer, batch_size) when batch_size > 0 do
      do_take_batch(buffer, batch_size, [])
    end

    @spec depth(t()) :: non_neg_integer()
    def depth(%__MODULE__{} = buffer), do: buffer.protected_len + buffer.regular_len

    @spec depths(t()) :: %{
            depth: non_neg_integer(),
            protected_depth: non_neg_integer(),
            regular_depth: non_neg_integer()
          }
    def depths(%__MODULE__{} = buffer) do
      %{
        depth: depth(buffer),
        protected_depth: buffer.protected_len,
        regular_depth: buffer.regular_len
      }
    end

    defp maybe_enqueue_regular(%__MODULE__{} = buffer, queued_envelope) do
      case admit_regular_success(buffer) do
        {:admit, buffer} ->
          do_enqueue(buffer, queued_envelope, :regular)

        {:drop, buffer} ->
          {_seq, envelope} = queued_envelope
          {buffer, envelope}
      end
    end

    defp admit_regular_success(%__MODULE__{} = buffer) do
      buffer = refresh_success_window(buffer, System.monotonic_time(:millisecond))

      if buffer.success_window_count >= buffer.sampling_policy.success_budget_per_minute do
        {:drop, buffer}
      else
        {:admit, %{buffer | success_window_count: buffer.success_window_count + 1}}
      end
    end

    defp refresh_success_window(%__MODULE__{success_window_started_ms: nil} = buffer, now_ms) do
      %{buffer | success_window_started_ms: now_ms, success_window_count: 0}
    end

    defp refresh_success_window(%__MODULE__{} = buffer, now_ms) do
      if now_ms - buffer.success_window_started_ms >= @success_window_ms do
        %{buffer | success_window_started_ms: now_ms, success_window_count: 0}
      else
        buffer
      end
    end

    defp do_enqueue(%__MODULE__{} = buffer, queued_envelope, :protected) do
      {buffer, dropped} =
        if buffer.protected_len >= buffer.protected_capacity and buffer.protected_capacity > 0 do
          {{:value, {_seq, dropped}}, queue} = :queue.out(buffer.protected_queue)
          {%{buffer | protected_queue: queue, protected_len: buffer.protected_len - 1}, dropped}
        else
          {buffer, nil}
        end

      queue = :queue.in(queued_envelope, buffer.protected_queue)

      {%{
         buffer
         | protected_queue: queue,
           protected_len: buffer.protected_len + 1,
           next_seq: buffer.next_seq + 1
       }, dropped}
    end

    defp do_enqueue(%__MODULE__{} = buffer, queued_envelope, :regular) do
      {buffer, dropped} =
        cond do
          buffer.regular_capacity == 0 ->
            {_seq, dropped} = queued_envelope
            {buffer, dropped}

          buffer.regular_len >= buffer.regular_capacity ->
            {{:value, {_seq, dropped}}, queue} = :queue.out(buffer.regular_queue)
            {%{buffer | regular_queue: queue, regular_len: buffer.regular_len - 1}, dropped}

          true ->
            {buffer, nil}
        end

      if buffer.regular_capacity == 0 do
        {buffer, dropped}
      else
        queue = :queue.in(queued_envelope, buffer.regular_queue)

        {%{
           buffer
           | regular_queue: queue,
             regular_len: buffer.regular_len + 1,
             next_seq: buffer.next_seq + 1
         }, dropped}
      end
    end

    defp do_take_batch(%__MODULE__{} = buffer, 0, acc), do: {Enum.reverse(acc), buffer}

    defp do_take_batch(%__MODULE__{} = buffer, _remaining, acc)
         when buffer.protected_len == 0 and buffer.regular_len == 0,
         do: {Enum.reverse(acc), buffer}

    defp do_take_batch(%__MODULE__{} = buffer, remaining, acc) do
      {queued_envelope, buffer} = pop_oldest(buffer)
      {_seq, envelope} = queued_envelope
      do_take_batch(buffer, remaining - 1, [envelope | acc])
    end

    defp pop_oldest(%__MODULE__{protected_len: 0, regular_len: regular_len} = buffer)
         when regular_len > 0 do
      {{:value, queued_envelope}, queue} = :queue.out(buffer.regular_queue)
      {queued_envelope, %{buffer | regular_queue: queue, regular_len: buffer.regular_len - 1}}
    end

    defp pop_oldest(%__MODULE__{regular_len: 0, protected_len: protected_len} = buffer)
         when protected_len > 0 do
      {{:value, queued_envelope}, queue} = :queue.out(buffer.protected_queue)

      {queued_envelope,
       %{buffer | protected_queue: queue, protected_len: buffer.protected_len - 1}}
    end

    defp pop_oldest(%__MODULE__{} = buffer) do
      {:value, {protected_seq, _} = protected_head} = :queue.peek(buffer.protected_queue)
      {:value, {regular_seq, _} = regular_head} = :queue.peek(buffer.regular_queue)

      if protected_seq <= regular_seq do
        {{:value, queued_envelope}, queue} = :queue.out(buffer.protected_queue)

        {queued_envelope || protected_head,
         %{buffer | protected_queue: queue, protected_len: buffer.protected_len - 1}}
      else
        {{:value, queued_envelope}, queue} = :queue.out(buffer.regular_queue)

        {queued_envelope || regular_head,
         %{buffer | regular_queue: queue, regular_len: buffer.regular_len - 1}}
      end
    end
  end

  @type state :: %{
          trace_port: module(),
          buffer: Buffer.t(),
          batch_size: pos_integer(),
          flush_interval_ms: non_neg_integer(),
          drain_scheduled?: boolean
        }
  @type buffer_depths :: %{
          depth: non_neg_integer(),
          protected_depth: non_neg_integer(),
          regular_depth: non_neg_integer()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec publish_trace(GenServer.server(), TraceEnvelope.t()) :: :ok | {:error, atom()}
  def publish_trace(server, %TraceEnvelope{} = envelope) do
    GenServer.call(server, {:publish_trace, envelope})
  end

  @spec publish_traces(GenServer.server(), [TraceEnvelope.t()]) :: :ok | {:error, atom()}
  def publish_traces(server, envelopes) when is_list(envelopes) do
    GenServer.call(server, {:publish_traces, envelopes})
  end

  @spec snapshot(GenServer.server()) :: buffer_depths()
  def snapshot(server), do: GenServer.call(server, :snapshot)

  @impl true
  def init(opts) do
    buffer_opts =
      [
        total_capacity: Keyword.get(opts, :buffer_capacity, 256),
        protected_capacity: Keyword.get(opts, :protected_error_capacity, 64)
      ] ++ Keyword.take(opts, [:sample_policy, :sample_rate_or_budget])

    state = %{
      trace_port: Keyword.get(opts, :trace_port, Citadel.TraceBridge),
      buffer: Buffer.new!(buffer_opts),
      batch_size: Keyword.get(opts, :batch_size, 20),
      flush_interval_ms: Keyword.get(opts, :flush_interval_ms, 10),
      drain_scheduled?: false
    }

    emit_depth_telemetry(state.buffer)
    {:ok, state}
  end

  @impl true
  def handle_call({:publish_trace, %TraceEnvelope{} = envelope}, _from, state) do
    {state, dropped} = enqueue_envelope(state, envelope)
    maybe_emit_drop_telemetry(dropped)
    emit_depth_telemetry(state.buffer)
    {:reply, :ok, maybe_schedule_drain(state)}
  end

  def handle_call({:publish_traces, envelopes}, _from, state) when is_list(envelopes) do
    {state, dropped} =
      Enum.reduce(envelopes, {state, []}, fn %TraceEnvelope{} = envelope,
                                             {state_acc, dropped_acc} ->
        {state_acc, dropped} = enqueue_envelope(state_acc, envelope)
        {state_acc, [dropped | dropped_acc]}
      end)

    Enum.each(dropped, &maybe_emit_drop_telemetry/1)
    emit_depth_telemetry(state.buffer)
    {:reply, :ok, maybe_schedule_drain(state)}
  end

  def handle_call(:snapshot, _from, state) do
    {:reply, Buffer.depths(state.buffer), state}
  end

  @impl true
  def handle_info(:drain, state) do
    {batch, buffer} = Buffer.take_batch(state.buffer, state.batch_size)
    state = %{state | buffer: buffer, drain_scheduled?: false}
    emit_depth_telemetry(state.buffer)

    state =
      case batch do
        [] ->
          state

        _batch ->
          case publish_batch(state.trace_port, batch) do
            :ok ->
              state

            {:error, reason_code} ->
              emit_failure_telemetry(reason_code, batch)
              state
          end
      end

    {:noreply, maybe_schedule_drain(state)}
  end

  defp enqueue_envelope(state, envelope) do
    {buffer, dropped} = Buffer.enqueue(state.buffer, envelope)
    {%{state | buffer: buffer}, dropped}
  end

  defp maybe_schedule_drain(%{drain_scheduled?: true} = state), do: state

  defp maybe_schedule_drain(%{buffer: buffer} = state) do
    if Buffer.depth(buffer) > 0 do
      Process.send_after(self(), :drain, state.flush_interval_ms)
      %{state | drain_scheduled?: true}
    else
      state
    end
  end

  defp publish_batch(trace_port, [envelope]) do
    publish_single(trace_port, envelope)
  end

  defp publish_batch(trace_port, batch) do
    if function_exported?(trace_port, :publish_traces, 1) do
      trace_port.publish_traces(batch)
    else
      Enum.reduce_while(batch, :ok, fn envelope, :ok ->
        case publish_single(trace_port, envelope) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp publish_single(trace_port, envelope) do
    if function_exported?(trace_port, :publish_trace, 1) do
      trace_port.publish_trace(envelope)
    else
      {:error, @unavailable_trace_backend_reason}
    end
  end

  defp emit_depth_telemetry(buffer) do
    :telemetry.execute(
      Telemetry.event_name(:trace_buffer_depth),
      Buffer.depths(buffer),
      %{}
    )
  end

  defp emit_failure_telemetry(reason_code, batch) when is_list(batch) do
    batch_size = length(batch)

    Enum.each(batch, fn %TraceEnvelope{} = envelope ->
      :telemetry.execute(
        Telemetry.event_name(:trace_publication_failure),
        %{count: 1, batch_size: batch_size},
        %{
          reason_code: reason_code,
          family: envelope.family
        }
        |> Map.merge(trace_envelope_metadata(envelope))
      )
    end)
  end

  defp maybe_emit_drop_telemetry(nil), do: :ok

  defp maybe_emit_drop_telemetry(%TraceEnvelope{} = dropped) do
    :telemetry.execute(
      Telemetry.event_name(:trace_publication_drop),
      %{count: 1},
      %{
        dropped_family: dropped.family,
        dropped_family_classification: TraceEnvelope.family_classification(dropped)
      }
      |> Map.merge(trace_envelope_metadata(dropped))
    )
  end

  defp trace_envelope_metadata(%TraceEnvelope{} = envelope) do
    %{
      trace_id: envelope.trace_id,
      tenant_id: envelope.tenant_id,
      request_id: envelope.request_id,
      decision_id: envelope.decision_id,
      boundary_ref: envelope.boundary_ref,
      trace_envelope_id: envelope.trace_envelope_id
    }
  end
end
