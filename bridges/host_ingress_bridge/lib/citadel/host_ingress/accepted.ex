defmodule Citadel.HostIngress.Accepted do
  @moduledoc """
  Typed successful result for the public host-ingress seam.
  """

  @schema_version 1
  @allowed_ingress_paths %{
    "direct_intent_envelope" => :direct_intent_envelope,
    "resolved_input" => :resolved_input
  }
  @allowed_lifecycle_events %{
    "attached" => :attached,
    "blocked" => :blocked,
    "live_owner" => :live_owner,
    "quarantined" => :quarantined,
    "resumed" => :resumed
  }

  @type attrs :: keyword() | %{optional(atom() | String.t()) => term()}

  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          request_id: String.t(),
          session_id: String.t() | nil,
          trace_id: String.t(),
          ingress_path: atom() | nil,
          lifecycle_event: atom() | nil,
          continuity_revision: non_neg_integer() | nil,
          entry_id: String.t() | nil,
          metadata: map()
        }

  @enforce_keys [:schema_version, :request_id, :trace_id]
  defstruct [
    :schema_version,
    :request_id,
    :session_id,
    :trace_id,
    :ingress_path,
    :lifecycle_event,
    :continuity_revision,
    :entry_id,
    metadata: %{}
  ]

  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @spec new!(attrs()) :: t()
  def new!(attrs) do
    attrs = Map.new(attrs)

    %__MODULE__{
      schema_version: optional_positive_integer(attrs, :schema_version, @schema_version),
      request_id: required_string!(attrs, :request_id),
      session_id: optional_string(attrs, :session_id),
      trace_id: required_string!(attrs, :trace_id),
      ingress_path: optional_atom(attrs, :ingress_path, @allowed_ingress_paths),
      lifecycle_event: optional_atom(attrs, :lifecycle_event, @allowed_lifecycle_events),
      continuity_revision: optional_non_neg_integer(attrs, :continuity_revision),
      entry_id: optional_string(attrs, :entry_id),
      metadata: normalize_metadata(attrs)
    }
  end

  defp required_string!(attrs, key) do
    value = Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))

    if is_binary(value) and String.trim(value) != "" do
      value
    else
      raise ArgumentError, "host ingress acceptance #{inspect(key)} must be a non-empty string"
    end
  end

  defp optional_string(attrs, key) do
    value = Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))

    if is_binary(value) and String.trim(value) != "" do
      value
    else
      nil
    end
  end

  defp optional_atom(attrs, key, allowed) do
    case Map.get(attrs, key, Map.get(attrs, Atom.to_string(key))) do
      nil ->
        nil

      value when is_atom(value) ->
        if value in Map.values(allowed) do
          value
        else
          raise ArgumentError,
                "host ingress acceptance #{inspect(key)} atom value must be one of #{inspect(Map.values(allowed))}, got: #{inspect(value)}"
        end

      value when is_binary(value) and value != "" ->
        case Map.fetch(allowed, value) do
          {:ok, atom} ->
            atom

          :error ->
            raise ArgumentError,
                  "host ingress acceptance #{inspect(key)} string value must be one of #{inspect(Map.keys(allowed))}, got: #{inspect(value)}"
        end

      value ->
        raise ArgumentError,
              "host ingress acceptance #{inspect(key)} must be an atom or string, got: #{inspect(value)}"
    end
  end

  defp optional_non_neg_integer(attrs, key) do
    case Map.get(attrs, key, Map.get(attrs, Atom.to_string(key))) do
      nil ->
        nil

      value when is_integer(value) and value >= 0 ->
        value

      value ->
        raise ArgumentError,
              "host ingress acceptance #{inspect(key)} must be a non-negative integer, got: #{inspect(value)}"
    end
  end

  defp optional_positive_integer(attrs, key, default) do
    case Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default)) do
      value when is_integer(value) and value > 0 ->
        value

      value ->
        raise ArgumentError,
              "host ingress acceptance #{inspect(key)} must be a positive integer, got: #{inspect(value)}"
    end
  end

  defp normalize_metadata(attrs) do
    known_keys = [
      :schema_version,
      :request_id,
      :session_id,
      :trace_id,
      :ingress_path,
      :lifecycle_event,
      :continuity_revision,
      :entry_id,
      :metadata
    ]

    metadata =
      Map.get(attrs, :metadata, Map.get(attrs, "metadata", %{}))

    if not is_map(metadata) do
      raise ArgumentError, "host ingress acceptance metadata must be a map"
    end

    extras =
      attrs
      |> Map.drop(known_keys ++ Enum.map(known_keys, &Atom.to_string/1))

    Map.merge(extras, metadata)
  end
end
