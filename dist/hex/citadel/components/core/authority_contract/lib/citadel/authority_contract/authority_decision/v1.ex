defmodule Citadel.AuthorityContract.AuthorityDecision.V1 do
  @moduledoc """
  Frozen `AuthorityDecision.v1` Brain authority packet.

  This module owns the field inventory and extension posture for the shared
  packet. Incompatible field or semantic changes require an explicit successor
  packet rather than mutation in place.
  """

  alias Citadel.ContractCore.AttrMap
  alias Citadel.ContractCore.CanonicalJson

  @packet_name "AuthorityDecision.v1"
  @contract_version "v1"
  @extensions_namespaces ["citadel"]
  @action_binding_key "for_action_ref"
  @schema [
    contract_version: {:literal, @contract_version},
    decision_id: :string,
    tenant_id: :string,
    request_id: :string,
    policy_version: :string,
    boundary_class: :string,
    trust_profile: :string,
    approval_profile: :string,
    egress_profile: :string,
    workspace_profile: :string,
    resource_profile: :string,
    decision_hash: :sha256_lower_hex,
    extensions: {:map, :citadel_namespaced_json}
  ]
  @required_fields Keyword.keys(@schema)

  @type t :: %__MODULE__{
          contract_version: String.t(),
          decision_id: String.t(),
          tenant_id: String.t(),
          request_id: String.t(),
          policy_version: String.t(),
          boundary_class: String.t(),
          trust_profile: String.t(),
          approval_profile: String.t(),
          egress_profile: String.t(),
          workspace_profile: String.t(),
          resource_profile: String.t(),
          decision_hash: String.t(),
          extensions: %{required(String.t()) => CanonicalJson.value()}
        }

  @enforce_keys @required_fields
  defstruct @required_fields

  @spec packet_name() :: String.t()
  def packet_name, do: @packet_name

  @spec contract_version() :: String.t()
  def contract_version, do: @contract_version

  @spec schema() :: keyword()
  def schema, do: @schema

  @spec required_fields() :: [atom()]
  def required_fields, do: @required_fields

  @spec extensions_namespaces() :: [String.t()]
  def extensions_namespaces, do: @extensions_namespaces

  @spec versioning_rule() :: atom()
  def versioning_rule, do: :explicit_successor_required_for_field_or_semantic_change

  @spec for_action_ref(t()) :: String.t() | nil
  def for_action_ref(%__MODULE__{} = packet) do
    packet.extensions
    |> Map.get("citadel", %{})
    |> case do
      %{} = citadel -> Map.get(citadel, @action_binding_key)
      _other -> nil
    end
    |> case do
      value when is_binary(value) and value != "" -> value
      _other -> nil
    end
  end

  @spec action_bound?(t()) :: boolean()
  def action_bound?(%__MODULE__{} = packet), do: not is_nil(for_action_ref(packet))

  @spec require_for_action_ref!(t()) :: String.t()
  def require_for_action_ref!(%__MODULE__{} = packet) do
    case for_action_ref(packet) do
      value when is_binary(value) ->
        value

      nil ->
        raise ArgumentError, "#{@packet_name}.extensions[\"citadel\"].for_action_ref is required"
    end
  end

  @spec new(t() | map() | keyword()) :: {:ok, t()} | {:error, Exception.t()}
  def new(%__MODULE__{} = packet), do: normalize(packet)

  def new(attrs) do
    {:ok, build!(attrs)}
  rescue
    error in ArgumentError -> {:error, error}
  end

  @spec new!(t() | map() | keyword()) :: t()
  def new!(%__MODULE__{} = packet) do
    case normalize(packet) do
      {:ok, normalized} -> normalized
      {:error, %ArgumentError{} = error} -> raise error
    end
  end

  def new!(attrs), do: build!(attrs)

  @spec dump(t()) :: map()
  def dump(%__MODULE__{} = packet) do
    %{
      contract_version: packet.contract_version,
      decision_id: packet.decision_id,
      tenant_id: packet.tenant_id,
      request_id: packet.request_id,
      policy_version: packet.policy_version,
      boundary_class: packet.boundary_class,
      trust_profile: packet.trust_profile,
      approval_profile: packet.approval_profile,
      egress_profile: packet.egress_profile,
      workspace_profile: packet.workspace_profile,
      resource_profile: packet.resource_profile,
      decision_hash: packet.decision_hash,
      extensions: packet.extensions
    }
  end

  @spec hash_payload(t()) :: map()
  def hash_payload(%__MODULE__{} = packet) do
    packet
    |> dump()
    |> Map.delete(:decision_hash)
  end

  defp build!(attrs) do
    attrs = AttrMap.normalize!(attrs, "#{@packet_name} attrs")

    %__MODULE__{
      contract_version:
        attrs
        |> AttrMap.fetch!(:contract_version, @packet_name)
        |> validate_contract_version!(),
      decision_id:
        attrs
        |> AttrMap.fetch!(:decision_id, @packet_name)
        |> validate_non_empty_string!(:decision_id),
      tenant_id:
        attrs
        |> AttrMap.fetch!(:tenant_id, @packet_name)
        |> validate_non_empty_string!(:tenant_id),
      request_id:
        attrs
        |> AttrMap.fetch!(:request_id, @packet_name)
        |> validate_non_empty_string!(:request_id),
      policy_version:
        attrs
        |> AttrMap.fetch!(:policy_version, @packet_name)
        |> validate_non_empty_string!(:policy_version),
      boundary_class:
        attrs
        |> AttrMap.fetch!(:boundary_class, @packet_name)
        |> validate_non_empty_string!(:boundary_class),
      trust_profile:
        attrs
        |> AttrMap.fetch!(:trust_profile, @packet_name)
        |> validate_non_empty_string!(:trust_profile),
      approval_profile:
        attrs
        |> AttrMap.fetch!(:approval_profile, @packet_name)
        |> validate_non_empty_string!(:approval_profile),
      egress_profile:
        attrs
        |> AttrMap.fetch!(:egress_profile, @packet_name)
        |> validate_non_empty_string!(:egress_profile),
      workspace_profile:
        attrs
        |> AttrMap.fetch!(:workspace_profile, @packet_name)
        |> validate_non_empty_string!(:workspace_profile),
      resource_profile:
        attrs
        |> AttrMap.fetch!(:resource_profile, @packet_name)
        |> validate_non_empty_string!(:resource_profile),
      decision_hash:
        attrs
        |> AttrMap.fetch!(:decision_hash, @packet_name)
        |> validate_decision_hash!(),
      extensions:
        attrs
        |> AttrMap.fetch!(:extensions, @packet_name)
        |> validate_extensions!("#{@packet_name}.extensions")
    }
  end

  defp normalize(%__MODULE__{} = packet) do
    {:ok,
     %__MODULE__{
       contract_version: validate_contract_version!(packet.contract_version),
       decision_id: validate_non_empty_string!(packet.decision_id, :decision_id),
       tenant_id: validate_non_empty_string!(packet.tenant_id, :tenant_id),
       request_id: validate_non_empty_string!(packet.request_id, :request_id),
       policy_version: validate_non_empty_string!(packet.policy_version, :policy_version),
       boundary_class: validate_non_empty_string!(packet.boundary_class, :boundary_class),
       trust_profile: validate_non_empty_string!(packet.trust_profile, :trust_profile),
       approval_profile: validate_non_empty_string!(packet.approval_profile, :approval_profile),
       egress_profile: validate_non_empty_string!(packet.egress_profile, :egress_profile),
       workspace_profile:
         validate_non_empty_string!(packet.workspace_profile, :workspace_profile),
       resource_profile: validate_non_empty_string!(packet.resource_profile, :resource_profile),
       decision_hash: validate_decision_hash!(packet.decision_hash),
       extensions: validate_extensions!(packet.extensions, "#{@packet_name}.extensions")
     }}
  rescue
    error in ArgumentError -> {:error, error}
  end

  defp validate_contract_version!(value) when value == @contract_version, do: value

  defp validate_contract_version!(value) do
    raise ArgumentError,
          "#{@packet_name}.contract_version must be #{@contract_version}, got: #{inspect(value)}"
  end

  defp validate_non_empty_string!(value, field) when is_binary(value) do
    if String.trim(value) == "" do
      raise ArgumentError, "#{@packet_name}.#{field} must be a non-empty string"
    end

    value
  end

  defp validate_non_empty_string!(value, field) do
    raise ArgumentError,
          "#{@packet_name}.#{field} must be a non-empty string, got: #{inspect(value)}"
  end

  defp validate_decision_hash!(value) when is_binary(value) do
    if lower_hex_64?(value) do
      value
    else
      raise ArgumentError,
            "#{@packet_name}.decision_hash must be lowercase SHA-256 hex, got: #{inspect(value)}"
    end
  end

  defp validate_decision_hash!(value) do
    raise ArgumentError,
          "#{@packet_name}.decision_hash must be lowercase SHA-256 hex, got: #{inspect(value)}"
  end

  defp lower_hex_64?(value) do
    byte_size(value) == 64 and
      value
      |> :binary.bin_to_list()
      |> Enum.all?(fn byte -> byte in ?0..?9 or byte in ?a..?f end)
  end

  defp validate_extensions!(value, field) do
    normalized = CanonicalJson.normalize!(value)

    unless is_map(normalized) do
      raise ArgumentError, "#{field} must normalize to a JSON object"
    end

    unknown_namespaces =
      normalized |> Map.keys() |> Enum.sort() |> Kernel.--(@extensions_namespaces)

    if unknown_namespaces != [] do
      raise ArgumentError,
            "#{field} only allows #{@extensions_namespaces |> inspect()} namespaces, got: " <>
              inspect(unknown_namespaces)
    end

    case Map.get(normalized, "citadel") do
      nil ->
        normalized

      nested when is_map(nested) ->
        normalized

      nested ->
        raise ArgumentError,
              "#{field}[\"citadel\"] must be a JSON object, got: #{inspect(nested)}"
    end
  end
end
