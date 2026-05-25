defmodule Citadel.RemoteFacade.Authority do
  @moduledoc """
  Citadel-owned authority facade for distributed StackLab profiles.

  Authority evaluation is a bounded synchronous seam. Callers pass serializable
  Context ABI packet and authority request maps; Citadel returns a bounded grant
  map or a safe failure map.
  """

  alias Citadel.ContextAuthority
  alias Citadel.ContextAuthority.Grant
  alias OuterBrain.ContextABI.{ContextPacket, Failure}

  @owner_group {__MODULE__, :authority}

  @spec owner_group() :: {module(), :authority}
  def owner_group, do: @owner_group

  @spec authorize(map(), keyword()) :: {:ok, map()} | {:error, map()}
  def authorize(request, opts \\ []) when is_map(request) and is_list(opts) do
    with {:ok, packet_attrs} <- fetch_map(request, "context_packet"),
         {:ok, authority_attrs} <- fetch_map(request, "authority_request"),
         {:ok, packet} <- ContextPacket.new(packet_attrs) do
      case ContextAuthority.authorize(packet, authority_attrs, opts) do
        {:ok, %Grant{} = grant} -> {:ok, Grant.dump(grant) |> stringify_keys()}
        {:error, %Failure{} = failure} -> {:error, failure_map(failure)}
      end
    else
      {:error, %Failure{} = failure} ->
        {:error, failure_map(failure)}

      {:error, reason} when is_map(reason) ->
        {:error, reason}
    end
  end

  defp fetch_map(request, "context_packet"),
    do: fetch_known_map(request, "context_packet", :context_packet)

  defp fetch_map(request, "authority_request"),
    do: fetch_known_map(request, "authority_request", :authority_request)

  defp fetch_known_map(request, string_key, atom_key) do
    case Map.get(request, string_key) || Map.get(request, atom_key) do
      value when is_map(value) -> {:ok, value}
      _other -> {:error, error(:invalid_envelope, %{"missing_field" => string_key})}
    end
  end

  defp failure_map(%Failure{} = failure) do
    %{
      "code" => "authority_denied",
      "owner" => Atom.to_string(failure.owner),
      "reason_code" => failure.reason_code,
      "safe_message" => failure.safe_message,
      "retryable" => failure.retryable?,
      "trace_ref" => failure.trace_ref,
      "evidence_refs" => failure.evidence_refs
    }
  end

  defp stringify_keys(map) do
    map
    |> Enum.map(fn {key, value} -> {to_string(key), stringify_value(value)} end)
    |> Map.new()
  end

  defp stringify_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp stringify_value(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value) when is_map(value), do: stringify_keys(value)
  defp stringify_value(value), do: value

  defp error(code, attrs) do
    Map.merge(
      %{
        "code" => Atom.to_string(code),
        "owner" => "citadel",
        "facade" => "authority"
      },
      attrs
    )
  end
end
