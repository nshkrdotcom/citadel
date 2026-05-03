defmodule Citadel.Governance.AccessGraphAuthorityCache do
  @moduledoc """
  Minimal authority-cache epoch state reconciled from access graph invalidations.
  """

  @enforce_keys [:tenant_ref, :snapshot_epoch]
  defstruct [
    :tenant_ref,
    :snapshot_epoch,
    :source_node_ref,
    :current_epoch,
    stale?: false
  ]

  @type t :: %__MODULE__{
          tenant_ref: String.t(),
          snapshot_epoch: non_neg_integer(),
          source_node_ref: String.t() | nil,
          current_epoch: non_neg_integer() | nil,
          stale?: boolean()
        }

  @spec new!(map() | keyword() | t()) :: t()
  def new!(%__MODULE__{} = cache), do: cache |> Map.from_struct() |> new!()

  def new!(attrs) when is_map(attrs) or is_list(attrs) do
    attrs = Map.new(attrs)

    %__MODULE__{
      tenant_ref: required_string!(attrs, :tenant_ref),
      snapshot_epoch: non_neg_integer!(Map.fetch!(attrs, :snapshot_epoch), :snapshot_epoch),
      source_node_ref: optional_string(attrs, :source_node_ref),
      current_epoch: optional_non_neg_integer(attrs, :current_epoch),
      stale?: Map.get(attrs, :stale?, false) == true
    }
  end

  @spec reconcile(t(), map()) :: {:fresh, t()} | {:stale, t()}
  def reconcile(%__MODULE__{} = cache, message) when is_map(message) do
    tenant_ref = value(message, :tenant_ref)
    epoch = graph_epoch(message)

    if tenant_ref == cache.tenant_ref and is_integer(epoch) and epoch > cache.snapshot_epoch do
      {:stale,
       %__MODULE__{
         cache
         | stale?: true,
           current_epoch: epoch,
           source_node_ref: value(message, :source_node_ref) || cache.source_node_ref
       }}
    else
      {:fresh, cache}
    end
  end

  @spec graph_topic!(String.t(), pos_integer()) :: String.t()
  def graph_topic!(tenant_ref, epoch) do
    topic!(["memory", "graph", hash_segment(tenant_ref), "epoch", positive_epoch!(epoch)])
  end

  defp graph_epoch(message) do
    metadata = value(message, :metadata) || %{}

    value(metadata, :new_epoch) ||
      value(metadata, :epoch) ||
      topic_epoch(value(message, :topic))
  end

  defp topic_epoch(topic) when is_binary(topic) do
    case String.split(topic, ".") do
      ["memory", "graph", _tenant_hash, "epoch", epoch] -> parse_positive_integer(epoch)
      _other -> nil
    end
  end

  defp topic_epoch(_topic), do: nil

  defp parse_positive_integer(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> integer
      _error -> nil
    end
  end

  defp hash_segment(ref) do
    ref
    |> require_string!(:tenant_ref)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp topic!(segments) do
    topic = Enum.map_join(segments, ".", &segment!/1)

    if topic_name?(topic) do
      topic
    else
      raise ArgumentError, "invalid graph topic: #{inspect(topic)}"
    end
  end

  defp segment!(segment) do
    segment = require_string!(segment, :topic_segment)

    if topic_segment?(segment) do
      segment
    else
      raise ArgumentError, "invalid graph topic segment: #{inspect(segment)}"
    end
  end

  defp positive_epoch!(epoch) when is_integer(epoch) and epoch > 0, do: Integer.to_string(epoch)

  defp positive_epoch!(epoch) do
    raise ArgumentError, "graph epoch must be a positive integer, got: #{inspect(epoch)}"
  end

  defp topic_name?(topic) do
    topic
    |> String.split(".")
    |> then(fn segments -> segments != [] and Enum.all?(segments, &topic_segment?/1) end)
  end

  defp topic_segment?(segment) do
    segment != "" and
      segment
      |> :binary.bin_to_list()
      |> Enum.all?(fn byte -> byte in ?a..?z or byte in ?0..?9 or byte in [?_, ?-] end)
  end

  defp required_string!(attrs, key), do: require_string!(value(attrs, key), key)

  defp require_string!(value, _key) when is_binary(value) and value != "", do: value

  defp require_string!(value, key) do
    raise ArgumentError, "#{key} must be a non-empty string, got: #{inspect(value)}"
  end

  defp optional_string(attrs, key) do
    case value(attrs, key) do
      string when is_binary(string) and string != "" -> string
      _other -> nil
    end
  end

  defp non_neg_integer!(value, _key) when is_integer(value) and value >= 0, do: value

  defp non_neg_integer!(value, key) do
    raise ArgumentError, "#{key} must be a non-negative integer, got: #{inspect(value)}"
  end

  defp optional_non_neg_integer(attrs, key) do
    case value(attrs, key) do
      nil -> nil
      value -> non_neg_integer!(value, key)
    end
  end

  defp value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
