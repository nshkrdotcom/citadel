defmodule Citadel.ObservabilityContract.AuditHashChain.V1 do
  @moduledoc """
  Immutable audit hash-chain evidence contract.

  Contract: `Platform.AuditHashChain.v1`.
  """

  alias Citadel.ContractCore.AttrMap

  @contract_name "Platform.AuditHashChain.v1"
  @contract_version "1.0.0"
  @genesis_hash "genesis"

  @fields [
    :contract_name,
    :contract_version,
    :tenant_ref,
    :installation_ref,
    :workspace_ref,
    :project_ref,
    :environment_ref,
    :principal_ref,
    :system_actor_ref,
    :resource_ref,
    :authority_packet_ref,
    :permission_decision_ref,
    :idempotency_key,
    :trace_id,
    :correlation_id,
    :release_manifest_ref,
    :audit_ref,
    :previous_hash,
    :event_hash,
    :chain_head_hash,
    :writer_ref,
    :immutability_proof_ref
  ]

  @enforce_keys @fields -- [:principal_ref, :system_actor_ref]
  defstruct @fields

  @type t :: %__MODULE__{}

  @spec contract_name() :: String.t()
  def contract_name, do: @contract_name

  @spec contract_version() :: String.t()
  def contract_version, do: @contract_version

  @spec genesis_hash() :: String.t()
  def genesis_hash, do: @genesis_hash

  @spec new(t() | map() | keyword()) :: {:ok, t()} | {:error, Exception.t()}
  def new(%__MODULE__{} = link), do: normalize(link)

  def new(attrs) do
    {:ok, build!(attrs)}
  rescue
    error in ArgumentError -> {:error, error}
  end

  @spec new!(t() | map() | keyword()) :: t()
  def new!(%__MODULE__{} = link) do
    case normalize(link) do
      {:ok, normalized} -> normalized
      {:error, %ArgumentError{} = error} -> raise error
    end
  end

  def new!(attrs), do: build!(attrs)

  @spec dump(t()) :: map()
  def dump(%__MODULE__{} = link) do
    @fields
    |> Map.new(&{&1, Map.fetch!(link, &1)})
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  @spec verify_link(t(), t()) :: :ok | {:error, :chain_continuity_violation}
  def verify_link(%__MODULE__{} = previous, %__MODULE__{} = next) do
    if next.previous_hash == previous.chain_head_hash do
      :ok
    else
      {:error, :chain_continuity_violation}
    end
  end

  defp build!(attrs) do
    attrs = AttrMap.normalize!(attrs, @contract_name)
    {principal_ref, system_actor_ref} = actor_refs!(attrs)

    %__MODULE__{
      contract_name:
        attrs
        |> AttrMap.get(:contract_name, @contract_name)
        |> literal!(@contract_name, :contract_name),
      contract_version:
        attrs
        |> AttrMap.get(:contract_version, @contract_version)
        |> literal!(@contract_version, :contract_version),
      tenant_ref: required_string!(attrs, :tenant_ref),
      installation_ref: required_string!(attrs, :installation_ref),
      workspace_ref: required_string!(attrs, :workspace_ref),
      project_ref: required_string!(attrs, :project_ref),
      environment_ref: required_string!(attrs, :environment_ref),
      principal_ref: principal_ref,
      system_actor_ref: system_actor_ref,
      resource_ref: required_string!(attrs, :resource_ref),
      authority_packet_ref: required_string!(attrs, :authority_packet_ref),
      permission_decision_ref: required_string!(attrs, :permission_decision_ref),
      idempotency_key: required_string!(attrs, :idempotency_key),
      trace_id: required_string!(attrs, :trace_id),
      correlation_id: required_string!(attrs, :correlation_id),
      release_manifest_ref: required_string!(attrs, :release_manifest_ref),
      audit_ref: required_string!(attrs, :audit_ref),
      previous_hash: previous_hash!(attrs),
      event_hash: sha256_hash!(attrs, :event_hash),
      chain_head_hash: sha256_hash!(attrs, :chain_head_hash),
      writer_ref: required_string!(attrs, :writer_ref),
      immutability_proof_ref: required_string!(attrs, :immutability_proof_ref)
    }
  end

  defp normalize(%__MODULE__{} = link) do
    {:ok, link |> dump() |> build!()}
  rescue
    error in ArgumentError -> {:error, error}
  end

  defp actor_refs!(attrs) do
    principal_ref = optional_string!(attrs, :principal_ref)
    system_actor_ref = optional_string!(attrs, :system_actor_ref)

    if is_nil(principal_ref) and is_nil(system_actor_ref) do
      raise ArgumentError, "#{@contract_name} requires principal_ref or system_actor_ref"
    end

    {principal_ref, system_actor_ref}
  end

  defp previous_hash!(attrs) do
    value = required_string!(attrs, :previous_hash)

    cond do
      value == @genesis_hash ->
        value

      sha256_hash?(value) ->
        value

      true ->
        raise ArgumentError,
              "#{@contract_name}.previous_hash must be genesis or a sha256 hash"
    end
  end

  defp sha256_hash!(attrs, key) do
    value = required_string!(attrs, key)

    if sha256_hash?(value) do
      value
    else
      raise ArgumentError, "#{@contract_name}.#{key} must be a sha256 hash"
    end
  end

  defp sha256_hash?(<<"sha256:", digest::binary-size(64)>>), do: lower_hex?(digest)
  defp sha256_hash?(_value), do: false

  defp lower_hex?(value) do
    value
    |> :binary.bin_to_list()
    |> Enum.all?(fn byte -> byte in ?0..?9 or byte in ?a..?f end)
  end

  defp required_string!(attrs, key) do
    attrs
    |> AttrMap.fetch!(key, @contract_name)
    |> string!(key)
  end

  defp optional_string!(attrs, key) do
    case AttrMap.get(attrs, key) do
      nil -> nil
      value -> string!(value, key)
    end
  end

  defp string!(value, _key) when is_binary(value) do
    if String.trim(value) == "" do
      raise ArgumentError, "#{@contract_name} fields must be non-empty strings"
    end

    value
  end

  defp string!(value, key) do
    raise ArgumentError,
          "#{@contract_name}.#{key} must be a non-empty string, got: #{inspect(value)}"
  end

  defp literal!(value, expected, _key) when value == expected, do: value

  defp literal!(value, expected, key) do
    raise ArgumentError, "#{@contract_name}.#{key} must be #{expected}, got: #{inspect(value)}"
  end
end
