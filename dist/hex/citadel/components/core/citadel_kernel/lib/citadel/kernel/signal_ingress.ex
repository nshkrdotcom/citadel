defmodule Citadel.Kernel.SignalIngress do
  @moduledoc """
  Always-on signal ingress root with per-session logical subscription isolation.
  """

  use GenServer

  alias Citadel.ObservabilityContract.Telemetry
  alias Citadel.Kernel.SessionDirectory
  alias Citadel.Kernel.SystemClock
  alias Citadel.RuntimeObservation
  alias Citadel.SignalIngressRebuildPolicy
  alias Jido.Integration.V2.SubjectRef

  @rebuild_message :rebuild_batch
  @eviction_sweep_message :eviction_sweep
  @allowed_delivery_order_scopes [
    :partition_fifo,
    :subject_fifo,
    :boundary_session_fifo,
    :unordered_dedupe_only
  ]
  @default_admission_policy %{
    bucket_capacity: 64,
    refill_rate_per_second: 64,
    max_queue_depth_per_partition: 128,
    max_in_flight_per_tenant_scope: 512,
    retry_after_ms: 100,
    delivery_order_scope: :partition_fifo,
    delivery_timeout_ms: 5_000,
    partition_overload_cooldown_ms: 1_000,
    post_admission_overload_action: :mark_partition_overloaded,
    replay_action: :replay_partition_after_retry
  }
  @default_eviction_policy %{
    sweep_interval_ms: 60_000,
    max_evictions_per_sweep: 128,
    subscription_ttl_ms: 15 * 60_000,
    consumer_ttl_ms: 15 * 60_000,
    rebuild_queue_ttl_ms: 15 * 60_000,
    partition_state_ttl_ms: 15 * 60_000,
    max_subscriptions_total: 100_000,
    max_subscriptions_per_tenant: 25_000,
    max_consumers_total: 100_000,
    max_rebuild_queue_total: 100_000,
    max_partitions_total: 50_000
  }

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def register_subscription(server \\ __MODULE__, session_id, opts \\ []) do
    GenServer.call(server, {:register_subscription, session_id, opts})
  end

  def unregister_subscription(server \\ __MODULE__, session_id) do
    GenServer.call(server, {:unregister_subscription, session_id})
  end

  def register_consumer(server \\ __MODULE__, session_id, pid) when is_pid(pid) do
    GenServer.call(server, {:register_consumer, session_id, pid})
  end

  def rebuild_from_directory(server \\ __MODULE__) do
    GenServer.call(server, :rebuild_from_directory)
  end

  def deliver_signal(server \\ __MODULE__, raw_signal) do
    GenServer.call(server, {:deliver_signal, raw_signal})
  end

  def deliver_observation(server \\ __MODULE__, %RuntimeObservation{} = observation) do
    deliver_signal(server, observation)
  end

  def subscription_state(server \\ __MODULE__, session_id) do
    GenServer.call(server, {:subscription_state, session_id})
  end

  def snapshot(server \\ __MODULE__) do
    GenServer.call(server, :snapshot)
  end

  def sweep_expired(server \\ __MODULE__) do
    GenServer.call(server, :sweep_expired)
  end

  @impl true
  def init(opts) do
    state =
      %{
        session_directory: Keyword.get(opts, :session_directory, SessionDirectory),
        signal_source: Keyword.fetch!(opts, :signal_source),
        clock: Keyword.get(opts, :clock, SystemClock),
        rebuild_policy: Keyword.get(opts, :rebuild_policy, SignalIngressRebuildPolicy.new!(%{})),
        transport_partition_fun:
          Keyword.get(opts, :transport_partition_fun, fn _cursor_info -> :default end),
        transport_reposition_fun:
          Keyword.get(opts, :transport_reposition_fun, fn _groups -> :ok end),
        admission_policy: normalize_admission_policy(Keyword.get(opts, :admission_policy, [])),
        eviction_policy: normalize_eviction_policy(Keyword.get(opts, :eviction_policy, [])),
        subscriptions: %{},
        consumers: %{},
        consumer_last_seen_at: %{},
        rebuild_queue: %{},
        rebuild_scheduled?: false,
        partition_workers: %{},
        partition_worker_monitors: %{},
        partition_queue_depths: %{},
        partition_overload_until_ms: %{},
        partition_last_seen_at_ms: %{},
        tenant_scope_in_flight: %{},
        token_buckets: %{},
        sweep_timer_ref: nil,
        restarted_at: Keyword.get(opts, :restarted_at, SystemClock.utc_now())
      }
      |> schedule_eviction_sweep()

    if Keyword.get(opts, :auto_rebuild?, false) do
      send(self(), @rebuild_message)
      {:ok, %{state | rebuild_scheduled?: true}}
    else
      {:ok, state}
    end
  end

  @impl true
  def handle_call({:register_subscription, session_id, opts}, _from, state) do
    priority_class = Keyword.get(opts, :priority_class, "background")
    committed_signal_cursor = Keyword.get(opts, :committed_signal_cursor)

    subscription = %{
      session_id: session_id,
      subscription_ref: Keyword.get(opts, :subscription_ref, "subscription/#{session_id}"),
      committed_signal_cursor: committed_signal_cursor,
      transport_cursor: Keyword.get(opts, :transport_cursor),
      status: Keyword.get(opts, :status, :active),
      priority_class: priority_class,
      registered_at: state.clock.utc_now(),
      last_seen_at: state.clock.utc_now(),
      tenant_scope_key: tenant_scope_from_opts(opts),
      rebuilt_at: state.clock.utc_now(),
      extensions: Keyword.get(opts, :extensions, %{})
    }

    case prepare_subscription_capacity(state, session_id, subscription.tenant_scope_key) do
      {:ok, state} ->
        state =
          state
          |> put_subscription(session_id, subscription)
          |> maybe_emit_high_priority_ready_latency(priority_class, subscription.registered_at)

        {:reply, :ok, state}

      {:error, rejection, state} ->
        {:reply, {:error, rejection}, state}
    end
  end

  def handle_call({:unregister_subscription, session_id}, _from, state) do
    {:reply, :ok,
     %{
       state
       | subscriptions: Map.delete(state.subscriptions, session_id),
         consumers: Map.delete(state.consumers, session_id),
         consumer_last_seen_at: Map.delete(state.consumer_last_seen_at, session_id)
     }}
  end

  def handle_call({:register_consumer, session_id, pid}, _from, state) do
    case prepare_consumer_capacity(state, session_id) do
      {:ok, state} ->
        {:reply, :ok,
         %{
           state
           | consumers: Map.put(state.consumers, session_id, pid),
             consumer_last_seen_at:
               Map.put(state.consumer_last_seen_at, session_id, state.clock.utc_now())
         }}

      {:error, rejection, state} ->
        {:reply, {:error, rejection}, state}
    end
  end

  def handle_call(:rebuild_from_directory, _from, state) do
    active_sessions =
      state.session_directory
      |> SessionDirectory.list_active_session_cursors()
      |> Map.new(fn cursor_info -> {cursor_info.session_id, cursor_info} end)

    case prepare_rebuild_queue_capacity(state, active_sessions) do
      {:ok, state} ->
        state =
          state
          |> Map.put(:rebuild_queue, Map.merge(state.rebuild_queue, active_sessions))
          |> schedule_rebuild()

        emit_rebuild_backlog_telemetry(state.rebuild_queue)
        {:reply, :ok, state}

      {:error, rejection, state} ->
        {:reply, {:error, rejection}, state}
    end
  end

  def handle_call({:deliver_signal, raw_signal}, _from, state) do
    case state.signal_source.normalize_signal(raw_signal) do
      {:ok, observation} ->
        case admit_observation(state, observation) do
          {:ok, acceptance, state} -> {:reply, {:ok, acceptance}, state}
          {:error, rejection, state} -> {:reply, {:error, rejection}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:subscription_state, session_id}, _from, state) do
    {:reply, Map.get(state.subscriptions, session_id), state}
  end

  def handle_call(:snapshot, _from, state) do
    {:reply,
     %{
       subscriptions: state.subscriptions,
       rebuild_queue: state.rebuild_queue,
       partition_queue_depths: state.partition_queue_depths,
       partition_overload_until_ms: state.partition_overload_until_ms,
       partition_last_seen_at_ms: state.partition_last_seen_at_ms,
       tenant_scope_in_flight: state.tenant_scope_in_flight,
       token_buckets: state.token_buckets,
       admission_policy: state.admission_policy,
       eviction_policy: state.eviction_policy,
       consumers: state.consumers,
       consumer_last_seen_at: state.consumer_last_seen_at,
       partition_workers: state.partition_workers
     }, state}
  end

  def handle_call(:sweep_expired, _from, state) do
    {state, summary} = sweep_expired_state(state)
    {:reply, summary, state}
  end

  @impl true
  def handle_info(@rebuild_message, state) do
    if map_size(state.rebuild_queue) == 0 do
      {:noreply, %{state | rebuild_scheduled?: false}}
    else
      {batch, remaining_queue} = take_rebuild_batch(state.rebuild_queue, state.rebuild_policy)
      started_at = System.monotonic_time(:millisecond)

      cursor_map =
        SessionDirectory.batch_load_committed_cursors(state.session_directory, Map.keys(batch))

      grouped = group_for_transport(cursor_map, state.transport_partition_fun)
      _ = state.transport_reposition_fun.(grouped)

      subscriptions =
        Enum.reduce(cursor_map, state.subscriptions, fn {session_id, cursor_info},
                                                        subscriptions ->
          Map.put(subscriptions, session_id, %{
            session_id: session_id,
            subscription_ref: "subscription/#{session_id}",
            committed_signal_cursor: cursor_info.committed_signal_cursor,
            transport_cursor: cursor_info.committed_signal_cursor,
            status: :rebuilt,
            priority_class: cursor_info.priority_class,
            registered_at: cursor_info.registered_at,
            rebuilt_at: state.clock.utc_now(),
            extensions: %{}
          })
        end)

      duration_ms = System.monotonic_time(:millisecond) - started_at
      priority_class = batch_priority_class(batch, state.rebuild_policy)

      :telemetry.execute(
        Telemetry.event_name(:signal_ingress_rebuild_batch_latency),
        %{duration_ms: max(duration_ms, 0)},
        %{priority_class: priority_class}
      )

      Enum.each(cursor_map, fn {_session_id, cursor_info} ->
        maybe_emit_high_priority_ready_latency(
          state,
          cursor_info.priority_class,
          cursor_info.registered_at
        )
      end)

      state =
        state
        |> Map.put(:subscriptions, subscriptions)
        |> Map.put(:rebuild_queue, remaining_queue)
        |> Map.put(:rebuild_scheduled?, map_size(remaining_queue) > 0)

      emit_rebuild_backlog_telemetry(remaining_queue)

      if map_size(remaining_queue) > 0 do
        Process.send_after(self(), @rebuild_message, state.rebuild_policy.batch_interval_ms)
      end

      {:noreply, state}
    end
  end

  def handle_info(
        {:signal_delivery_finished, partition_ref, _accepted_ref, tenant_scope_key,
         delivery_result},
        state
      ) do
    state =
      state
      |> release_admission_reservation(partition_ref, tenant_scope_key)
      |> maybe_mark_partition_overloaded(partition_ref, delivery_result)

    {:noreply, state}
  end

  def handle_info({:DOWN, monitor_ref, :process, _pid, _reason}, state) do
    case Map.pop(state.partition_worker_monitors, monitor_ref) do
      {nil, _worker_monitors} ->
        {:noreply, state}

      {partition_ref, worker_monitors} ->
        {:noreply,
         %{
           state
           | partition_workers: Map.delete(state.partition_workers, partition_ref),
             partition_worker_monitors: worker_monitors
         }}
    end
  end

  def handle_info(@eviction_sweep_message, state) do
    {state, _summary} = sweep_expired_state(state)
    {:noreply, schedule_eviction_sweep(%{state | sweep_timer_ref: nil})}
  end

  defp admit_observation(state, %RuntimeObservation{} = observation) do
    with {:ok, partition} <- partition_for_observation(observation, state.admission_policy),
         {:ok, partition} <-
           require_ingress_lineage(state, observation, partition, state.admission_policy),
         {:ok, state} <- reject_if_partition_overloaded(state, partition),
         {:ok, state} <- ensure_partition_capacity(state, partition),
         {:ok, state, bucket} <- reserve_partition_token(state, partition),
         {:ok, state} <- reserve_queue_slot(state, partition),
         {:ok, state, partition_worker} <- ensure_partition_worker(state, partition) do
      accepted_ref = accepted_ref()

      delivery = %{
        accepted_ref: accepted_ref,
        partition_ref: partition.ref,
        tenant_scope_key: partition.tenant_scope_key,
        observation: observation,
        consumer_pid: Map.get(state.consumers, observation.session_id),
        delivery_order_scope: partition.delivery_order_scope,
        delivery_timeout_ms: state.admission_policy.delivery_timeout_ms,
        overload_cooldown_ms: state.admission_policy.partition_overload_cooldown_ms,
        overload_action: state.admission_policy.post_admission_overload_action,
        replay_action: state.admission_policy.replay_action
      }

      state =
        state
        |> increment_tenant_scope_in_flight(partition.tenant_scope_key)
        |> update_subscription_cursor(observation, partition.lineage.source_anchor)
        |> touch_consumer(observation.session_id)
        |> touch_partition(partition.ref)
        |> emit_signal_lag(observation)

      __MODULE__.PartitionWorker.deliver(partition_worker, delivery)

      {:ok, acceptance_evidence(accepted_ref, partition, partition_worker, bucket, state), state}
    else
      {:error, %{reason: :missing_partition_key_fields} = rejection} ->
        {:error, rejection, state}

      {:error, %{reason: :missing_lineage_fields} = rejection} ->
        {:error, rejection, state}

      {:error, %{reason: :regressed_source_position_or_revision} = rejection} ->
        {:error, rejection, state}

      {:error, rejection, state} ->
        {:error, rejection, state}
    end
  end

  defp reject_if_partition_overloaded(state, partition) do
    now_ms = System.monotonic_time(:millisecond)

    case Map.get(state.partition_overload_until_ms, partition.ref) do
      nil ->
        {:ok, state}

      overload_until_ms when overload_until_ms <= now_ms ->
        {:ok,
         update_in(state.partition_overload_until_ms, fn overloads ->
           Map.delete(overloads, partition.ref)
         end)}

      overload_until_ms ->
        queue_depth = Map.get(state.partition_queue_depths, partition.ref, 0)

        tenant_scope_in_flight =
          Map.get(state.tenant_scope_in_flight, partition.tenant_scope_key, 0)

        retry_after_ms = max(overload_until_ms - now_ms, 0)

        {:error,
         admission_rejection(
           :partition_overloaded,
           partition,
           state,
           queue_depth,
           tenant_scope_in_flight,
           retry_after_ms
         ), state}
    end
  end

  defp emit_signal_lag(state, observation) do
    lag_ms = DateTime.diff(state.clock.utc_now(), observation.event_at, :millisecond)

    :telemetry.execute(
      Telemetry.event_name(:signal_ingress_lag),
      %{lag_ms: max(lag_ms, 0)},
      %{source: observation.event_kind}
    )

    state
  end

  defp update_subscription_cursor(state, observation, source_anchor) do
    update_in(state.subscriptions, fn subscriptions ->
      case Map.get(subscriptions, observation.session_id) do
        nil ->
          subscriptions

        subscription ->
          Map.put(subscriptions, observation.session_id, %{
            subscription
            | transport_cursor: observation.signal_cursor || subscription.transport_cursor,
              extensions: remember_source_anchor(subscription.extensions, source_anchor),
              last_seen_at: state.clock.utc_now()
          })
      end
    end)
  end

  defp touch_consumer(state, session_id) do
    if Map.has_key?(state.consumers, session_id) do
      %{
        state
        | consumer_last_seen_at:
            Map.put(state.consumer_last_seen_at, session_id, state.clock.utc_now())
      }
    else
      state
    end
  end

  defp touch_partition(state, partition_ref) do
    put_in(state.partition_last_seen_at_ms[partition_ref], System.monotonic_time(:millisecond))
  end

  defp partition_for_observation(%RuntimeObservation{} = observation, admission_policy) do
    tenant_id = field_value(observation, "tenant_id")
    authority_scope = field_value(observation, "authority_scope")
    boundary_session_id = field_value(observation, "boundary_session_id")
    subject_ref = observation.subject_ref

    missing_fields =
      []
      |> maybe_missing(:tenant_id, tenant_id)
      |> maybe_missing(:authority_scope, authority_scope)

    cond do
      missing_fields != [] ->
        {:error, missing_partition_fields_rejection(missing_fields, admission_policy)}

      match?(%SubjectRef{}, subject_ref) ->
        subject_ref_map = SubjectRef.dump(subject_ref)
        partition_ref = {:subject, tenant_id, authority_scope, subject_ref.ref}

        {:ok,
         %{
           ref: partition_ref,
           key: %{
             tenant_id: tenant_id,
             authority_scope: authority_scope,
             subject_ref: subject_ref_map
           },
           tenant_scope_key: {tenant_id, authority_scope},
           delivery_order_scope: admission_policy.delivery_order_scope,
           dedupe_key: {partition_ref, dedupe_component(observation)}
         }}

      present_string?(boundary_session_id) ->
        partition_ref = {:boundary_session, tenant_id, authority_scope, boundary_session_id}

        {:ok,
         %{
           ref: partition_ref,
           key: %{
             tenant_id: tenant_id,
             authority_scope: authority_scope,
             boundary_session_id: boundary_session_id
           },
           tenant_scope_key: {tenant_id, authority_scope},
           delivery_order_scope: :boundary_session_fifo,
           dedupe_key: {partition_ref, dedupe_component(observation)}
         }}

      true ->
        {:error,
         missing_partition_fields_rejection(
           [:subject_ref_or_boundary_session_id],
           admission_policy
         )}
    end
  end

  defp require_ingress_lineage(
         state,
         %RuntimeObservation{} = observation,
         partition,
         admission_policy
       ) do
    case lineage_for_observation(observation) do
      {:ok, lineage} ->
        case source_anchor_regression(state, observation, lineage.source_anchor) do
          :ok ->
            {:ok, Map.put(partition, :lineage, lineage)}

          {:error, previous_anchor, current_anchor} ->
            {:error,
             source_anchor_regression_rejection(previous_anchor, current_anchor, admission_policy)}
        end

      {:error, missing_fields} ->
        {:error, missing_lineage_fields_rejection(missing_fields, admission_policy)}
    end
  end

  defp lineage_for_observation(%RuntimeObservation{} = observation) do
    trace_id = field_value(observation, "trace_id")

    causation_id =
      field_value(observation, "causation_id") || present_string(observation.request_id)

    canonical_idempotency_key =
      field_value(observation, "canonical_idempotency_key") ||
        field_value(observation, "idempotency_key")

    source_anchor = source_anchor(observation)

    missing_fields =
      []
      |> maybe_missing(:trace_id, trace_id)
      |> maybe_missing(:causation_id, causation_id)
      |> maybe_missing(:canonical_idempotency_key, canonical_idempotency_key)
      |> maybe_missing(:source_position_or_revision, Map.get(source_anchor, :value))

    if missing_fields == [] do
      {:ok,
       %{
         trace_id: trace_id,
         causation_id: causation_id,
         canonical_idempotency_key: canonical_idempotency_key,
         source_anchor: source_anchor
       }}
    else
      {:error, Enum.reverse(missing_fields)}
    end
  end

  defp source_anchor(%RuntimeObservation{} = observation) do
    source_position =
      field_value(observation, "source_position") ||
        present_string(observation.signal_cursor)

    source_revision =
      field_value(observation, "source_revision") ||
        field_value(observation, "revision")

    cond do
      present_string?(source_position) -> %{kind: :source_position, value: source_position}
      present_string?(source_revision) -> %{kind: :revision, value: source_revision}
      true -> %{kind: nil, value: nil}
    end
  end

  defp source_anchor_regression(state, %RuntimeObservation{} = observation, current_anchor) do
    state.subscriptions
    |> Map.get(observation.session_id)
    |> previous_source_anchor()
    |> case do
      nil ->
        :ok

      previous_anchor ->
        if source_anchor_regressed?(previous_anchor, current_anchor) do
          {:error, previous_anchor, current_anchor}
        else
          :ok
        end
    end
  end

  defp previous_source_anchor(nil), do: nil

  defp previous_source_anchor(subscription) do
    extension_anchor =
      subscription.extensions
      |> Map.get("lineage_source_anchor")
      |> normalize_stored_source_anchor()

    extension_anchor ||
      source_position_anchor(subscription.transport_cursor) ||
      source_position_anchor(subscription.committed_signal_cursor) ||
      revision_anchor(Map.get(subscription.extensions, "source_revision")) ||
      revision_anchor(Map.get(subscription.extensions, "revision"))
  end

  defp source_position_anchor(value) do
    if present_string?(value), do: %{kind: :source_position, value: value}
  end

  defp revision_anchor(value) do
    if present_string?(value), do: %{kind: :revision, value: value}
  end

  defp normalize_stored_source_anchor(%{kind: kind, value: value}),
    do: normalize_source_anchor(kind, value)

  defp normalize_stored_source_anchor(%{"kind" => kind, "value" => value}),
    do: normalize_source_anchor(kind, value)

  defp normalize_stored_source_anchor(_anchor), do: nil

  defp normalize_source_anchor(kind, value) when kind in [:source_position, "source_position"],
    do: source_position_anchor(value)

  defp normalize_source_anchor(kind, value) when kind in [:revision, "revision"],
    do: revision_anchor(value)

  defp normalize_source_anchor(_kind, _value), do: nil

  defp source_anchor_regressed?(%{kind: kind, value: previous}, %{kind: kind, value: current}) do
    case {source_anchor_ordinal(previous), source_anchor_ordinal(current)} do
      {{:ok, previous_ordinal}, {:ok, current_ordinal}} -> current_ordinal < previous_ordinal
      _other -> false
    end
  end

  defp source_anchor_regressed?(_previous_anchor, _current_anchor), do: false

  defp source_anchor_ordinal(value) when is_integer(value), do: {:ok, value}

  defp source_anchor_ordinal(value) when is_binary(value) do
    value
    |> trailing_digits()
    |> case do
      "" -> :unknown
      digits -> parse_delimited_trailing_digits(value, digits)
    end
  end

  defp source_anchor_ordinal(_value), do: :unknown

  defp trailing_digits(value) do
    value
    |> String.to_charlist()
    |> Enum.reverse()
    |> Enum.take_while(fn byte -> byte in ?0..?9 end)
    |> Enum.reverse()
    |> List.to_string()
  end

  defp parse_delimited_trailing_digits(value, digits) do
    prefix_size = byte_size(value) - byte_size(digits)

    cond do
      prefix_size == 0 ->
        {:ok, String.to_integer(digits)}

      binary_part(value, prefix_size - 1, 1) in ["/", ":", "-"] ->
        {:ok, String.to_integer(digits)}

      true ->
        :unknown
    end
  end

  defp remember_source_anchor(extensions, %{kind: kind, value: value})
       when kind in [:source_position, :revision] and is_binary(value) do
    Map.put(extensions, "lineage_source_anchor", %{
      "kind" => Atom.to_string(kind),
      "value" => value
    })
  end

  defp remember_source_anchor(extensions, _source_anchor), do: extensions

  defp reserve_partition_token(state, partition) do
    tenant_scope_in_flight = Map.get(state.tenant_scope_in_flight, partition.tenant_scope_key, 0)

    if tenant_scope_in_flight >= state.admission_policy.max_in_flight_per_tenant_scope do
      queue_depth = Map.get(state.partition_queue_depths, partition.ref, 0)

      {:error,
       admission_rejection(
         :tenant_scope_in_flight_exhausted,
         partition,
         state,
         queue_depth,
         tenant_scope_in_flight
       ), state}
    else
      {bucket, state} = refreshed_token_bucket(state, partition.ref)

      if bucket.tokens <= 0 do
        queue_depth = Map.get(state.partition_queue_depths, partition.ref, 0)

        {:error,
         admission_rejection(
           :partition_token_exhausted,
           partition,
           state,
           queue_depth,
           tenant_scope_in_flight
         ), state}
      else
        bucket = %{bucket | tokens: bucket.tokens - 1}
        {:ok, put_in(state.token_buckets[partition.ref], bucket), bucket}
      end
    end
  end

  defp reserve_queue_slot(state, partition) do
    queue_depth = Map.get(state.partition_queue_depths, partition.ref, 0)
    tenant_scope_in_flight = Map.get(state.tenant_scope_in_flight, partition.tenant_scope_key, 0)

    if queue_depth >= state.admission_policy.max_queue_depth_per_partition do
      {:error,
       admission_rejection(
         :partition_queue_full,
         partition,
         state,
         queue_depth,
         tenant_scope_in_flight
       ), state}
    else
      {:ok,
       put_in(
         state.partition_queue_depths[partition.ref],
         queue_depth + 1
       )}
    end
  end

  defp ensure_partition_capacity(state, partition) do
    if known_partition?(state, partition.ref) or
         partition_count(state) < state.eviction_policy.max_partitions_total do
      {:ok, state}
    else
      {state, _summary} = sweep_expired_partitions(state, :capacity)

      if partition_count(state) < state.eviction_policy.max_partitions_total do
        {:ok, state}
      else
        queue_depth = Map.get(state.partition_queue_depths, partition.ref, 0)

        tenant_scope_in_flight =
          Map.get(state.tenant_scope_in_flight, partition.tenant_scope_key, 0)

        {:error,
         admission_rejection(
           :partition_capacity_exhausted,
           partition,
           state,
           queue_depth,
           tenant_scope_in_flight
         ), state}
      end
    end
  end

  defp ensure_partition_worker(state, partition) do
    case Map.get(state.partition_workers, partition.ref) do
      pid when is_pid(pid) ->
        if Process.alive?(pid) do
          {:ok, state, pid}
        else
          start_partition_worker(
            %{state | partition_workers: Map.delete(state.partition_workers, partition.ref)},
            partition
          )
        end

      _missing ->
        start_partition_worker(state, partition)
    end
  end

  defp start_partition_worker(state, partition) do
    case __MODULE__.PartitionWorker.start(
           owner: self(),
           partition_ref: partition.ref
         ) do
      {:ok, pid} ->
        monitor_ref = Process.monitor(pid)

        {:ok,
         %{
           state
           | partition_workers: Map.put(state.partition_workers, partition.ref, pid),
             partition_worker_monitors:
               Map.put(state.partition_worker_monitors, monitor_ref, partition.ref)
         }, pid}

      {:error, reason} ->
        {:error,
         %{
           reason: :partition_worker_unavailable,
           details: reason,
           partition_key: partition.key,
           safe_action: :retry_after,
           retry_after_ms: state.admission_policy.retry_after_ms,
           resource_exhaustion?: true
         }, state}
    end
  end

  defp refreshed_token_bucket(state, partition_ref) do
    now_ms = System.monotonic_time(:millisecond)
    policy = state.admission_policy

    bucket =
      Map.get(state.token_buckets, partition_ref, %{
        tokens: policy.bucket_capacity,
        last_refill_ms: now_ms
      })

    elapsed_ms = max(now_ms - bucket.last_refill_ms, 0)
    refill_tokens = div(elapsed_ms * policy.refill_rate_per_second, 1_000)

    bucket =
      if refill_tokens > 0 do
        %{
          bucket
          | tokens: min(policy.bucket_capacity, bucket.tokens + refill_tokens),
            last_refill_ms: now_ms
        }
      else
        bucket
      end

    {bucket, put_in(state.token_buckets[partition_ref], bucket)}
  end

  defp acceptance_evidence(accepted_ref, partition, partition_worker, bucket, state) do
    %{
      accepted_ref: accepted_ref,
      partition_ref: partition.ref,
      partition_key: partition.key,
      tenant_scope_key: partition.tenant_scope_key,
      delivery_order_scope: partition.delivery_order_scope,
      dedupe_key: partition.dedupe_key,
      lineage: partition.lineage,
      token_bucket: %{
        capacity: state.admission_policy.bucket_capacity,
        refill_rate_per_second: state.admission_policy.refill_rate_per_second,
        tokens_remaining: bucket.tokens
      },
      tenant_scope_in_flight:
        Map.get(state.tenant_scope_in_flight, partition.tenant_scope_key, 0),
      queue_depth: Map.get(state.partition_queue_depths, partition.ref, 0),
      delivery_timeout_ms: state.admission_policy.delivery_timeout_ms,
      partition_overload_cooldown_ms: state.admission_policy.partition_overload_cooldown_ms,
      overload_action: state.admission_policy.post_admission_overload_action,
      replay_action: state.admission_policy.replay_action,
      async_handoff?: true,
      partition_worker: partition_worker
    }
  end

  defp admission_rejection(reason, partition, state, queue_depth, tenant_scope_in_flight) do
    admission_rejection(
      reason,
      partition,
      state,
      queue_depth,
      tenant_scope_in_flight,
      state.admission_policy.retry_after_ms
    )
  end

  defp admission_rejection(
         reason,
         partition,
         state,
         queue_depth,
         tenant_scope_in_flight,
         retry_after_ms
       ) do
    rejection = %{
      reason: reason,
      safe_action: :retry_after,
      retry_after_ms: retry_after_ms,
      resource_exhaustion?: true,
      partition_ref: partition.ref,
      partition_key: partition.key,
      tenant_scope_key: partition.tenant_scope_key,
      delivery_order_scope: partition.delivery_order_scope,
      queue_depth_before: queue_depth,
      queue_depth_after: queue_depth,
      tenant_scope_in_flight: tenant_scope_in_flight,
      overload_action: state.admission_policy.post_admission_overload_action,
      replay_action: state.admission_policy.replay_action
    }

    :telemetry.execute(
      Telemetry.event_name(:signal_ingress_admission_rejection),
      %{
        queue_depth: queue_depth,
        tenant_scope_in_flight: tenant_scope_in_flight,
        retry_after_ms: retry_after_ms
      },
      %{reason_code: reason, delivery_order_scope: partition.delivery_order_scope}
    )

    rejection
  end

  defp missing_partition_fields_rejection(missing_fields, admission_policy) do
    %{
      reason: :missing_partition_key_fields,
      missing_fields: Enum.reverse(missing_fields),
      safe_action: :reject,
      retry_after_ms: nil,
      resource_exhaustion?: false,
      delivery_order_scope: admission_policy.delivery_order_scope
    }
  end

  defp missing_lineage_fields_rejection(missing_fields, admission_policy) do
    %{
      reason: :missing_lineage_fields,
      missing_fields: missing_fields,
      safe_action: :reject,
      retry_after_ms: nil,
      resource_exhaustion?: false,
      delivery_order_scope: admission_policy.delivery_order_scope
    }
  end

  defp source_anchor_regression_rejection(previous_anchor, current_anchor, admission_policy) do
    %{
      reason: :regressed_source_position_or_revision,
      previous_source_anchor: previous_anchor,
      current_source_anchor: current_anchor,
      safe_action: :reject,
      retry_after_ms: nil,
      resource_exhaustion?: false,
      delivery_order_scope: admission_policy.delivery_order_scope
    }
  end

  defp increment_tenant_scope_in_flight(state, tenant_scope_key) do
    update_in(state.tenant_scope_in_flight, fn tenant_scope_in_flight ->
      Map.update(tenant_scope_in_flight, tenant_scope_key, 1, &(&1 + 1))
    end)
  end

  defp release_admission_reservation(state, partition_ref, tenant_scope_key) do
    state
    |> update_in([:partition_queue_depths], &decrement_counter(&1, partition_ref))
    |> update_in([:tenant_scope_in_flight], &decrement_counter(&1, tenant_scope_key))
    |> touch_partition(partition_ref)
  end

  defp maybe_mark_partition_overloaded(state, partition_ref, %{
         delivery_status: delivery_status,
         retry_after_ms: retry_after_ms
       })
       when delivery_status in [:timed_out, :deferred_for_replay] do
    overload_until_ms = System.monotonic_time(:millisecond) + retry_after_ms

    update_in(state.partition_overload_until_ms, fn overloads ->
      Map.put(overloads, partition_ref, overload_until_ms)
    end)
  end

  defp maybe_mark_partition_overloaded(state, _partition_ref, _delivery_result), do: state

  defp prepare_subscription_capacity(state, session_id, tenant_scope_key) do
    state =
      state
      |> sweep_expired_consumers(:sweep)
      |> elem(0)
      |> sweep_expired_subscriptions(:sweep)
      |> elem(0)

    with {:ok, state} <- ensure_subscription_total_capacity(state, session_id),
         {:ok, state} <- ensure_subscription_tenant_capacity(state, session_id, tenant_scope_key) do
      {:ok, state}
    end
  end

  defp ensure_subscription_total_capacity(state, session_id) do
    if Map.has_key?(state.subscriptions, session_id) or
         map_size(state.subscriptions) < state.eviction_policy.max_subscriptions_total do
      {:ok, state}
    else
      state =
        evict_subscription_candidates(
          state,
          inactive_subscription_candidates(state),
          1,
          :capacity
        )

      if map_size(state.subscriptions) < state.eviction_policy.max_subscriptions_total do
        {:ok, state}
      else
        {:error,
         capacity_rejection(
           :subscription_capacity_exhausted,
           :subscriptions,
           map_size(state.subscriptions),
           state.eviction_policy.max_subscriptions_total
         ), state}
      end
    end
  end

  defp ensure_subscription_tenant_capacity(state, session_id, tenant_scope_key) do
    if Map.has_key?(state.subscriptions, session_id) do
      {:ok, state}
    else
      count =
        state.subscriptions
        |> Map.values()
        |> Enum.count(&(Map.get(&1, :tenant_scope_key, :default) == tenant_scope_key))

      if count < state.eviction_policy.max_subscriptions_per_tenant do
        {:ok, state}
      else
        candidates =
          state
          |> inactive_subscription_candidates()
          |> Enum.filter(fn {_session_id, subscription} ->
            Map.get(subscription, :tenant_scope_key, :default) == tenant_scope_key
          end)

        state = evict_subscription_candidates(state, candidates, 1, :capacity)

        updated_count =
          state.subscriptions
          |> Map.values()
          |> Enum.count(&(Map.get(&1, :tenant_scope_key, :default) == tenant_scope_key))

        if updated_count < state.eviction_policy.max_subscriptions_per_tenant do
          {:ok, state}
        else
          {:error,
           capacity_rejection(
             :subscription_tenant_capacity_exhausted,
             :subscriptions,
             updated_count,
             state.eviction_policy.max_subscriptions_per_tenant
           ), state}
        end
      end
    end
  end

  defp prepare_consumer_capacity(state, session_id) do
    state = sweep_expired_consumers(state, :sweep) |> elem(0)

    if Map.has_key?(state.consumers, session_id) or
         map_size(state.consumers) < state.eviction_policy.max_consumers_total do
      {:ok, state}
    else
      state = evict_dead_consumers(state, 1)

      if map_size(state.consumers) < state.eviction_policy.max_consumers_total do
        {:ok, state}
      else
        {:error,
         capacity_rejection(
           :consumer_capacity_exhausted,
           :consumers,
           map_size(state.consumers),
           state.eviction_policy.max_consumers_total
         ), state}
      end
    end
  end

  defp prepare_rebuild_queue_capacity(state, active_sessions) do
    state = sweep_expired_rebuild_queue(state, :sweep) |> elem(0)

    new_session_count =
      MapSet.size(
        MapSet.difference(
          MapSet.new(Map.keys(active_sessions)),
          MapSet.new(Map.keys(state.rebuild_queue))
        )
      )

    projected_size = map_size(state.rebuild_queue) + new_session_count

    if projected_size <= state.eviction_policy.max_rebuild_queue_total do
      {:ok, state}
    else
      {state, _count} = sweep_expired_rebuild_queue(state, :capacity)

      new_session_count =
        MapSet.size(
          MapSet.difference(
            MapSet.new(Map.keys(active_sessions)),
            MapSet.new(Map.keys(state.rebuild_queue))
          )
        )

      projected_size = map_size(state.rebuild_queue) + new_session_count

      if projected_size <= state.eviction_policy.max_rebuild_queue_total do
        {:ok, state}
      else
        {:error,
         capacity_rejection(
           :rebuild_queue_capacity_exhausted,
           :rebuild_queue,
           projected_size,
           state.eviction_policy.max_rebuild_queue_total
         ), state}
      end
    end
  end

  defp sweep_expired_state(state) do
    {state, consumers} = sweep_expired_consumers(state, :sweep)
    {state, subscriptions} = sweep_expired_subscriptions(state, :sweep)
    {state, rebuild_queue} = sweep_expired_rebuild_queue(state, :sweep)
    {state, partitions} = sweep_expired_partitions(state, :sweep)

    {state,
     %{
       subscriptions: subscriptions,
       consumers: consumers,
       rebuild_queue: rebuild_queue,
       partitions: partitions
     }}
  end

  defp sweep_expired_subscriptions(state, mode) do
    candidates =
      state
      |> inactive_subscription_candidates()
      |> Enum.filter(fn {_session_id, subscription} ->
        ttl_expired?(Map.get(subscription, :last_seen_at) || subscription.registered_at, state)
      end)

    evict_count = bounded_evict_count(state, candidates, mode)
    state = evict_subscription_candidates(state, candidates, evict_count, mode)
    {state, evict_count}
  end

  defp inactive_subscription_candidates(state) do
    state.subscriptions
    |> Enum.reject(fn {session_id, _subscription} ->
      Map.has_key?(state.consumers, session_id) or Map.has_key?(state.rebuild_queue, session_id)
    end)
    |> Enum.sort_by(fn {_session_id, subscription} ->
      Map.get(subscription, :last_seen_at) || subscription.registered_at
    end)
  end

  defp evict_subscription_candidates(state, candidates, count, _mode) do
    session_ids =
      candidates
      |> Enum.take(count)
      |> Enum.map(fn {session_id, _subscription} -> session_id end)

    %{
      state
      | subscriptions: Map.drop(state.subscriptions, session_ids),
        consumers: Map.drop(state.consumers, session_ids),
        consumer_last_seen_at: Map.drop(state.consumer_last_seen_at, session_ids)
    }
  end

  defp sweep_expired_consumers(state, mode) do
    candidates =
      state.consumers
      |> Enum.filter(fn {session_id, pid} ->
        consumer_expired?(state, session_id, pid)
      end)
      |> Enum.sort_by(fn {session_id, _pid} ->
        Map.get(state.consumer_last_seen_at, session_id, state.restarted_at)
      end)

    evict_count = bounded_evict_count(state, candidates, mode)
    state = evict_consumers(state, candidates, evict_count)
    {state, evict_count}
  end

  defp evict_dead_consumers(state, count) do
    candidates =
      state.consumers
      |> Enum.filter(fn {_session_id, pid} -> not Process.alive?(pid) end)
      |> Enum.sort_by(fn {session_id, _pid} ->
        Map.get(state.consumer_last_seen_at, session_id, state.restarted_at)
      end)

    evict_consumers(state, candidates, count)
  end

  defp evict_consumers(state, candidates, count) do
    session_ids =
      candidates
      |> Enum.take(count)
      |> Enum.map(fn {session_id, _pid} -> session_id end)

    %{
      state
      | consumers: Map.drop(state.consumers, session_ids),
        consumer_last_seen_at: Map.drop(state.consumer_last_seen_at, session_ids)
    }
  end

  defp consumer_expired?(state, session_id, pid) do
    last_seen_at = Map.get(state.consumer_last_seen_at, session_id, state.restarted_at)
    not Process.alive?(pid) and ttl_expired?(last_seen_at, state, :consumer_ttl_ms)
  end

  defp sweep_expired_rebuild_queue(state, mode) do
    candidates =
      state.rebuild_queue
      |> Enum.filter(fn {_session_id, cursor_info} ->
        ttl_expired?(cursor_info.registered_at, state, :rebuild_queue_ttl_ms)
      end)
      |> Enum.sort_by(fn {_session_id, cursor_info} -> cursor_info.registered_at end)

    evict_count = bounded_evict_count(state, candidates, mode)

    session_ids =
      candidates
      |> Enum.take(evict_count)
      |> Enum.map(fn {session_id, _cursor_info} -> session_id end)

    {%{state | rebuild_queue: Map.drop(state.rebuild_queue, session_ids)}, evict_count}
  end

  defp sweep_expired_partitions(state, mode) do
    candidates =
      state
      |> idle_partition_candidates()
      |> Enum.filter(fn {_partition_ref, last_seen_ms} ->
        mode == :capacity or partition_ttl_expired?(state, last_seen_ms)
      end)
      |> Enum.sort_by(fn {_partition_ref, last_seen_ms} -> last_seen_ms end)

    evict_count = bounded_evict_count(state, candidates, mode)

    state =
      candidates
      |> Enum.take(evict_count)
      |> Enum.reduce(state, fn {partition_ref, _last_seen_ms}, state ->
        evict_partition_state(state, partition_ref)
      end)

    {state, evict_count}
  end

  defp idle_partition_candidates(state) do
    state
    |> partition_refs()
    |> Enum.filter(fn partition_ref ->
      Map.get(state.partition_queue_depths, partition_ref, 0) == 0 and
        not Map.has_key?(state.partition_overload_until_ms, partition_ref)
    end)
    |> Enum.map(fn partition_ref ->
      {partition_ref, Map.get(state.partition_last_seen_at_ms, partition_ref, 0)}
    end)
  end

  defp evict_partition_state(state, partition_ref) do
    state =
      case Map.get(state.partition_workers, partition_ref) do
        pid when is_pid(pid) ->
          Process.exit(pid, :shutdown)
          %{state | partition_workers: Map.delete(state.partition_workers, partition_ref)}

        _missing ->
          state
      end

    monitor_refs =
      state.partition_worker_monitors
      |> Enum.filter(fn {_monitor_ref, ref} -> ref == partition_ref end)
      |> Enum.map(fn {monitor_ref, _ref} -> monitor_ref end)

    Enum.each(monitor_refs, &Process.demonitor(&1, [:flush]))

    %{
      state
      | partition_worker_monitors: Map.drop(state.partition_worker_monitors, monitor_refs),
        partition_queue_depths: Map.delete(state.partition_queue_depths, partition_ref),
        partition_overload_until_ms: Map.delete(state.partition_overload_until_ms, partition_ref),
        partition_last_seen_at_ms: Map.delete(state.partition_last_seen_at_ms, partition_ref),
        token_buckets: Map.delete(state.token_buckets, partition_ref)
    }
  end

  defp known_partition?(state, partition_ref) do
    Map.has_key?(state.partition_workers, partition_ref) or
      Map.has_key?(state.token_buckets, partition_ref) or
      Map.has_key?(state.partition_queue_depths, partition_ref) or
      Map.has_key?(state.partition_overload_until_ms, partition_ref) or
      Map.has_key?(state.partition_last_seen_at_ms, partition_ref)
  end

  defp partition_count(state), do: state |> partition_refs() |> length()

  defp partition_refs(state) do
    [
      Map.keys(state.partition_workers),
      Map.keys(state.token_buckets),
      Map.keys(state.partition_queue_depths),
      Map.keys(state.partition_overload_until_ms),
      Map.keys(state.partition_last_seen_at_ms)
    ]
    |> List.flatten()
    |> Enum.uniq()
  end

  defp bounded_evict_count(state, candidates, :capacity) do
    min(length(candidates), state.eviction_policy.max_evictions_per_sweep)
  end

  defp bounded_evict_count(state, candidates, :sweep) do
    min(length(candidates), state.eviction_policy.max_evictions_per_sweep)
  end

  defp ttl_expired?(nil, _state), do: false
  defp ttl_expired?(timestamp, state), do: ttl_expired?(timestamp, state, :subscription_ttl_ms)

  defp ttl_expired?(%DateTime{} = timestamp, state, field) do
    DateTime.diff(state.clock.utc_now(), timestamp, :millisecond) >=
      Map.fetch!(state.eviction_policy, field)
  end

  defp ttl_expired?(_timestamp, _state, _field), do: false

  defp partition_ttl_expired?(state, last_seen_ms) do
    System.monotonic_time(:millisecond) - last_seen_ms >=
      state.eviction_policy.partition_state_ttl_ms
  end

  defp capacity_rejection(reason, segment, count, ceiling) do
    %{
      reason: reason,
      safe_action: :retry_after,
      retry_after_ms: 100,
      resource_exhaustion?: true,
      segment: segment,
      count: count,
      ceiling: ceiling
    }
  end

  defp decrement_counter(counters, key) do
    case Map.get(counters, key, 0) do
      value when value <= 1 -> Map.delete(counters, key)
      value -> Map.put(counters, key, value - 1)
    end
  end

  defp normalize_admission_policy(opts) when is_list(opts) do
    opts
    |> Map.new()
    |> normalize_admission_policy()
  end

  defp normalize_admission_policy(opts) when is_map(opts) do
    policy = Map.merge(@default_admission_policy, opts)
    delivery_order_scope = Map.fetch!(policy, :delivery_order_scope)

    unless delivery_order_scope in @allowed_delivery_order_scopes do
      raise ArgumentError,
            "SignalIngress delivery_order_scope must be one of #{inspect(@allowed_delivery_order_scopes)}"
    end

    %{
      bucket_capacity: positive_integer!(policy.bucket_capacity, :bucket_capacity),
      refill_rate_per_second:
        non_negative_integer!(policy.refill_rate_per_second, :refill_rate_per_second),
      max_queue_depth_per_partition:
        positive_integer!(
          policy.max_queue_depth_per_partition,
          :max_queue_depth_per_partition
        ),
      max_in_flight_per_tenant_scope:
        positive_integer!(
          policy.max_in_flight_per_tenant_scope,
          :max_in_flight_per_tenant_scope
        ),
      retry_after_ms: non_negative_integer!(policy.retry_after_ms, :retry_after_ms),
      delivery_order_scope: delivery_order_scope,
      delivery_timeout_ms: positive_integer!(policy.delivery_timeout_ms, :delivery_timeout_ms),
      partition_overload_cooldown_ms:
        non_negative_integer!(
          policy.partition_overload_cooldown_ms,
          :partition_overload_cooldown_ms
        ),
      post_admission_overload_action: policy.post_admission_overload_action,
      replay_action: policy.replay_action
    }
  end

  defp normalize_eviction_policy(opts) when is_list(opts) do
    opts
    |> Map.new()
    |> normalize_eviction_policy()
  end

  defp normalize_eviction_policy(opts) when is_map(opts) do
    policy = Map.merge(@default_eviction_policy, opts)

    %{
      sweep_interval_ms: non_negative_integer!(policy.sweep_interval_ms, :sweep_interval_ms),
      max_evictions_per_sweep:
        positive_integer!(policy.max_evictions_per_sweep, :max_evictions_per_sweep),
      subscription_ttl_ms:
        non_negative_integer!(policy.subscription_ttl_ms, :subscription_ttl_ms),
      consumer_ttl_ms: non_negative_integer!(policy.consumer_ttl_ms, :consumer_ttl_ms),
      rebuild_queue_ttl_ms:
        non_negative_integer!(policy.rebuild_queue_ttl_ms, :rebuild_queue_ttl_ms),
      partition_state_ttl_ms:
        non_negative_integer!(policy.partition_state_ttl_ms, :partition_state_ttl_ms),
      max_subscriptions_total:
        positive_integer!(policy.max_subscriptions_total, :max_subscriptions_total),
      max_subscriptions_per_tenant:
        positive_integer!(
          policy.max_subscriptions_per_tenant,
          :max_subscriptions_per_tenant
        ),
      max_consumers_total: positive_integer!(policy.max_consumers_total, :max_consumers_total),
      max_rebuild_queue_total:
        positive_integer!(policy.max_rebuild_queue_total, :max_rebuild_queue_total),
      max_partitions_total: positive_integer!(policy.max_partitions_total, :max_partitions_total)
    }
  end

  defp positive_integer!(value, _field) when is_integer(value) and value > 0, do: value

  defp positive_integer!(value, field) do
    raise ArgumentError,
          "SignalIngress #{field} must be a positive integer, got: #{inspect(value)}"
  end

  defp non_negative_integer!(value, _field) when is_integer(value) and value >= 0, do: value

  defp non_negative_integer!(value, field) do
    raise ArgumentError,
          "SignalIngress #{field} must be a non-negative integer, got: #{inspect(value)}"
  end

  defp field_value(%RuntimeObservation{} = observation, field) do
    observation.extensions
    |> Map.get(field)
    |> present_string()
    |> case do
      nil ->
        observation.payload
        |> Map.get(field)
        |> present_string()

      value ->
        value
    end
  end

  defp present_string(value) when is_binary(value) and value != "", do: value
  defp present_string(_value), do: nil

  defp present_string?(value), do: not is_nil(present_string(value))

  defp maybe_missing(missing_fields, field, value) do
    if present_string?(value), do: missing_fields, else: [field | missing_fields]
  end

  defp tenant_scope_from_opts(opts) do
    Keyword.get(opts, :tenant_scope_key) ||
      case {Keyword.get(opts, :tenant_id), Keyword.get(opts, :authority_scope)} do
        {tenant_id, authority_scope} when is_binary(tenant_id) and is_binary(authority_scope) ->
          {tenant_id, authority_scope}

        _other ->
          :default
      end
  end

  defp dedupe_component(%RuntimeObservation{} = observation) do
    field_value(observation, "canonical_idempotency_key") ||
      field_value(observation, "idempotency_key") ||
      field_value(observation, "causation_id") ||
      observation.signal_id
  end

  defp accepted_ref do
    "signal-ingress/#{System.unique_integer([:positive, :monotonic])}"
  end

  defp schedule_rebuild(%{rebuild_scheduled?: true} = state), do: state

  defp schedule_rebuild(state) do
    Process.send_after(self(), @rebuild_message, 0)
    %{state | rebuild_scheduled?: true}
  end

  defp schedule_eviction_sweep(state) do
    if state.eviction_policy.sweep_interval_ms > 0 do
      %{
        state
        | sweep_timer_ref:
            Process.send_after(
              self(),
              @eviction_sweep_message,
              state.eviction_policy.sweep_interval_ms
            )
      }
    else
      state
    end
  end

  defp take_rebuild_batch(rebuild_queue, %SignalIngressRebuildPolicy{} = rebuild_policy) do
    rebuild_queue
    |> Enum.sort_by(fn {_session_id, cursor_info} ->
      {SignalIngressRebuildPolicy.priority_rank(rebuild_policy, cursor_info.priority_class),
       cursor_info.registered_at}
    end)
    |> Enum.split(rebuild_policy.max_sessions_per_batch)
    |> then(fn {selected, remaining} -> {Map.new(selected), Map.new(remaining)} end)
  end

  defp group_for_transport(cursor_map, partition_fun) do
    cursor_map
    |> Map.values()
    |> Enum.group_by(partition_fun)
  end

  defp batch_priority_class(batch, %SignalIngressRebuildPolicy{} = rebuild_policy) do
    batch
    |> Map.values()
    |> Enum.min_by(
      &SignalIngressRebuildPolicy.priority_rank(rebuild_policy, &1.priority_class),
      fn -> %{priority_class: "background"} end
    )
    |> Map.get(:priority_class)
  end

  defp emit_rebuild_backlog_telemetry(rebuild_queue) do
    rebuild_queue
    |> Map.values()
    |> Enum.group_by(& &1.priority_class)
    |> Enum.each(fn {priority_class, entries} ->
      :telemetry.execute(
        Telemetry.event_name(:signal_ingress_rebuild_backlog),
        %{count: length(entries)},
        %{priority_class: priority_class}
      )
    end)
  end

  defp maybe_emit_high_priority_ready_latency(state, priority_class, registered_at) do
    if priority_class in ["explicit_resume", "live_request", "pending_replay_safe"] do
      duration_ms =
        DateTime.diff(state.clock.utc_now(), registered_at || state.restarted_at, :millisecond)

      :telemetry.execute(
        Telemetry.event_name(:signal_ingress_high_priority_ready_latency),
        %{duration_ms: max(duration_ms, 0)},
        %{}
      )
    end

    state
  end

  defp put_subscription(state, session_id, subscription) do
    %{state | subscriptions: Map.put(state.subscriptions, session_id, subscription)}
  end
end

defmodule Citadel.Kernel.SignalIngress.PartitionWorker do
  @moduledoc false

  use GenServer

  alias Citadel.ObservabilityContract.Telemetry
  alias Citadel.Kernel.SessionServer

  def start(opts) do
    GenServer.start(__MODULE__, opts)
  end

  def deliver(worker, delivery) when is_pid(worker) do
    GenServer.cast(worker, {:deliver, delivery})
  end

  @impl true
  def init(opts) do
    owner = Keyword.fetch!(opts, :owner)

    {:ok,
     %{
       owner: owner,
       owner_monitor_ref: Process.monitor(owner),
       partition_ref: Keyword.fetch!(opts, :partition_ref),
       overloaded_until_ms: nil
     }}
  end

  @impl true
  def handle_cast({:deliver, delivery}, state) do
    {delivery_result, state} = deliver_with_overload_boundary(delivery, state)

    send(
      state.owner,
      {:signal_delivery_finished, delivery.partition_ref, delivery.accepted_ref,
       delivery.tenant_scope_key, delivery_result}
    )

    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, monitor_ref, :process, owner, _reason}, state)
      when monitor_ref == state.owner_monitor_ref and owner == state.owner do
    {:stop, :normal, state}
  end

  defp deliver_with_overload_boundary(delivery, state) do
    now_ms = System.monotonic_time(:millisecond)

    if is_integer(state.overloaded_until_ms) and state.overloaded_until_ms > now_ms do
      retry_after_ms = state.overloaded_until_ms - now_ms

      result =
        delivery_result(
          delivery,
          :deferred_for_replay,
          :partition_overloaded,
          0,
          retry_after_ms
        )

      emit_delivery_overload(result)
      {result, state}
    else
      deliver_to_consumer(delivery, state)
    end
  end

  defp deliver_to_consumer(delivery, state) do
    started_at = System.monotonic_time(:millisecond)

    try do
      case delivery.consumer_pid do
        nil ->
          :ok

        pid ->
          SessionServer.record_runtime_observation(
            pid,
            delivery.observation,
            timeout: delivery.delivery_timeout_ms
          )
      end

      {delivery_result(delivery, :delivered, :none, elapsed_ms(started_at), 0), state}
    catch
      :exit, {:timeout, _details} ->
        timeout_result(delivery, state, started_at, :consumer_timeout)

      :exit, :timeout ->
        timeout_result(delivery, state, started_at, :consumer_timeout)

      :exit, {:noproc, _details} ->
        {delivery_result(delivery, :consumer_unavailable, :noproc, elapsed_ms(started_at), 0),
         state}

      :exit, :noproc ->
        {delivery_result(delivery, :consumer_unavailable, :noproc, elapsed_ms(started_at), 0),
         state}
    end
  end

  defp timeout_result(delivery, state, started_at, reason) do
    retry_after_ms = delivery.overload_cooldown_ms

    result =
      delivery_result(
        delivery,
        :timed_out,
        reason,
        elapsed_ms(started_at),
        retry_after_ms
      )

    emit_delivery_overload(result)

    {result,
     %{
       state
       | overloaded_until_ms: System.monotonic_time(:millisecond) + retry_after_ms
     }}
  end

  defp delivery_result(delivery, status, reason, duration_ms, retry_after_ms) do
    %{
      delivery_status: status,
      reason: reason,
      duration_ms: max(duration_ms, 0),
      retry_after_ms: retry_after_ms,
      delivery_order_scope: delivery.delivery_order_scope,
      overload_action: delivery.overload_action,
      replay_action: delivery.replay_action
    }
  end

  defp emit_delivery_overload(result) do
    :telemetry.execute(
      Telemetry.event_name(:signal_ingress_delivery_overload),
      %{duration_ms: result.duration_ms, retry_after_ms: result.retry_after_ms},
      %{
        reason_code: result.reason,
        delivery_order_scope: result.delivery_order_scope,
        replay_action: result.replay_action
      }
    )
  end

  defp elapsed_ms(started_at) do
    System.monotonic_time(:millisecond) - started_at
  end
end
