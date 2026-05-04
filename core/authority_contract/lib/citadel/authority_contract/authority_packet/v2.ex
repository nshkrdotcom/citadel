defmodule Citadel.AuthorityContract.AuthorityPacket.V2 do
  @moduledoc """
  Phase 4 authority packet contract for governed substrate and operator seams.

  `AuthorityPacketV2` is intentionally wider than the frozen
  `AuthorityDecision.v1` packet. It carries the enterprise pre-cut envelope
  fields needed by downstream systems to replay, audit, reject, and join a
  governed action without re-deciding policy.
  """

  alias Citadel.ContractCore.AttrMap
  alias Citadel.ContractCore.CanonicalJson

  @packet_name "Citadel.AuthorityPacketV2.v1"
  @contract_version "1.0.0"
  @extensions_namespaces ["citadel"]
  @max_authority_hash_inline_bytes 1_000_000

  @fields [
    :contract_name,
    :contract_version,
    :authority_packet_ref,
    :permission_decision_ref,
    :tenant_ref,
    :installation_ref,
    :workspace_ref,
    :project_ref,
    :environment_ref,
    :principal_ref,
    :system_actor_ref,
    :system_authorization_ref,
    :provider_family,
    :provider_ref,
    :provider_account_ref,
    :connector_instance_ref,
    :connector_binding_ref,
    :credential_handle_ref,
    :credential_lease_ref,
    :native_auth_assertion_ref,
    :operation_policy_ref,
    :operation_scope_ref,
    :target_ref,
    :attach_grant_ref,
    :authority_decision_ref,
    :redaction_ref,
    :resource_ref,
    :subject_ref,
    :action,
    :policy_revision,
    :installation_revision,
    :activation_epoch,
    :boundary_class,
    :trust_profile,
    :approval_profile,
    :egress_profile,
    :workspace_profile,
    :resource_profile,
    :idempotency_key,
    :trace_id,
    :correlation_id,
    :release_manifest_ref,
    :decision_hash,
    :canonical_json_hash,
    :extensions
  ]

  @phase2_optional_refs [
    :principal_ref,
    :system_actor_ref,
    :system_authorization_ref,
    :provider_family,
    :provider_ref,
    :provider_account_ref,
    :connector_instance_ref,
    :connector_binding_ref,
    :credential_handle_ref,
    :credential_lease_ref,
    :native_auth_assertion_ref,
    :operation_policy_ref,
    :operation_scope_ref,
    :target_ref,
    :attach_grant_ref,
    :authority_decision_ref,
    :redaction_ref
  ]

  @enforce_keys @fields -- @phase2_optional_refs
  defstruct @fields

  @type json_ref :: String.t() | %{required(String.t()) => CanonicalJson.value()}

  @type t :: %__MODULE__{
          contract_name: String.t(),
          contract_version: String.t(),
          authority_packet_ref: String.t(),
          permission_decision_ref: String.t(),
          tenant_ref: json_ref(),
          installation_ref: json_ref(),
          workspace_ref: json_ref(),
          project_ref: json_ref(),
          environment_ref: json_ref(),
          principal_ref: json_ref() | nil,
          system_actor_ref: json_ref() | nil,
          system_authorization_ref: json_ref() | nil,
          provider_family: String.t() | nil,
          provider_ref: json_ref() | nil,
          provider_account_ref: json_ref() | nil,
          connector_instance_ref: json_ref() | nil,
          connector_binding_ref: json_ref() | nil,
          credential_handle_ref: json_ref() | nil,
          credential_lease_ref: json_ref() | nil,
          native_auth_assertion_ref: json_ref() | nil,
          operation_policy_ref: json_ref() | nil,
          operation_scope_ref: json_ref() | nil,
          target_ref: json_ref() | nil,
          attach_grant_ref: json_ref() | nil,
          authority_decision_ref: json_ref() | nil,
          redaction_ref: json_ref() | nil,
          resource_ref: json_ref(),
          subject_ref: json_ref(),
          action: String.t(),
          policy_revision: String.t(),
          installation_revision: non_neg_integer(),
          activation_epoch: non_neg_integer(),
          boundary_class: String.t(),
          trust_profile: String.t(),
          approval_profile: String.t(),
          egress_profile: String.t(),
          workspace_profile: String.t(),
          resource_profile: String.t(),
          idempotency_key: String.t(),
          trace_id: String.t(),
          correlation_id: String.t(),
          release_manifest_ref: String.t(),
          decision_hash: String.t(),
          canonical_json_hash: String.t(),
          extensions: %{required(String.t()) => CanonicalJson.value()}
        }

  @spec packet_name() :: String.t()
  def packet_name, do: @packet_name

  @spec contract_version() :: String.t()
  def contract_version, do: @contract_version

  @spec required_fields() :: [atom()]
  def required_fields, do: @enforce_keys ++ [:principal_ref_or_system_actor_ref]

  @spec extensions_namespaces() :: [String.t()]
  def extensions_namespaces, do: @extensions_namespaces

  @spec max_authority_hash_inline_bytes() :: pos_integer()
  def max_authority_hash_inline_bytes, do: @max_authority_hash_inline_bytes

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
    @fields
    |> Map.new(&{&1, Map.fetch!(packet, &1)})
    |> reject_nil_refs()
  end

  @spec hash_payload(t() | map()) :: map()
  def hash_payload(%__MODULE__{} = packet), do: packet |> dump() |> hash_payload()

  def hash_payload(payload) when is_map(payload) do
    payload
    |> CanonicalJson.normalize!()
    |> Map.delete("decision_hash")
    |> Map.delete("canonical_json_hash")
  end

  @spec canonical_payload!(t() | map()) :: String.t()
  def canonical_payload!(packet_or_payload) do
    packet_or_payload
    |> hash_payload()
    |> CanonicalJson.encode_inline!(
      max_bytes: @max_authority_hash_inline_bytes,
      label: "AuthorityPacketV2 hash input"
    )
  end

  @spec authority_hash!(t() | map() | keyword()) :: String.t()
  def authority_hash!(%__MODULE__{} = packet), do: packet |> canonical_payload!() |> sha256()

  def authority_hash!(attrs) do
    attrs
    |> put_pending_hashes()
    |> build!()
    |> authority_hash!()
  end

  @spec put_hashes!(t() | map() | keyword()) :: t()
  def put_hashes!(%__MODULE__{} = packet), do: packet |> dump() |> put_hashes!()

  def put_hashes!(attrs) do
    pending_packet =
      attrs
      |> put_pending_hashes()
      |> build!()

    hash = authority_hash!(pending_packet)

    pending_packet
    |> dump()
    |> Map.put(:decision_hash, hash)
    |> Map.put(:canonical_json_hash, hash)
    |> build!()
  end

  @spec hashes_valid?(t()) :: boolean()
  def hashes_valid?(%__MODULE__{} = packet) do
    hash = authority_hash!(packet)
    packet.decision_hash == hash and packet.canonical_json_hash == hash
  end

  defp build!(attrs) do
    attrs = AttrMap.normalize!(attrs, "#{@packet_name} attrs")

    principal_ref = optional_ref(attrs, :principal_ref)
    system_actor_ref = optional_ref(attrs, :system_actor_ref)
    validate_actor_pair!(principal_ref, system_actor_ref)

    %__MODULE__{
      contract_name:
        attrs
        |> AttrMap.fetch!(:contract_name, @packet_name)
        |> validate_literal!(@packet_name, :contract_name),
      contract_version:
        attrs
        |> AttrMap.fetch!(:contract_version, @packet_name)
        |> validate_literal!(@contract_version, :contract_version),
      authority_packet_ref:
        attrs
        |> AttrMap.fetch!(:authority_packet_ref, @packet_name)
        |> string!(:authority_packet_ref),
      permission_decision_ref:
        attrs
        |> AttrMap.fetch!(:permission_decision_ref, @packet_name)
        |> string!(:permission_decision_ref),
      tenant_ref: attrs |> AttrMap.fetch!(:tenant_ref, @packet_name) |> ref!(:tenant_ref),
      installation_ref:
        attrs |> AttrMap.fetch!(:installation_ref, @packet_name) |> ref!(:installation_ref),
      workspace_ref:
        attrs |> AttrMap.fetch!(:workspace_ref, @packet_name) |> ref!(:workspace_ref),
      project_ref: attrs |> AttrMap.fetch!(:project_ref, @packet_name) |> ref!(:project_ref),
      environment_ref:
        attrs |> AttrMap.fetch!(:environment_ref, @packet_name) |> ref!(:environment_ref),
      principal_ref: principal_ref,
      system_actor_ref: system_actor_ref,
      system_authorization_ref: optional_ref(attrs, :system_authorization_ref),
      provider_family: optional_string(attrs, :provider_family),
      provider_ref: optional_ref(attrs, :provider_ref),
      provider_account_ref: optional_ref(attrs, :provider_account_ref),
      connector_instance_ref: optional_ref(attrs, :connector_instance_ref),
      connector_binding_ref: optional_ref(attrs, :connector_binding_ref),
      credential_handle_ref: optional_ref(attrs, :credential_handle_ref),
      credential_lease_ref: optional_ref(attrs, :credential_lease_ref),
      native_auth_assertion_ref: optional_ref(attrs, :native_auth_assertion_ref),
      operation_policy_ref: optional_ref(attrs, :operation_policy_ref),
      operation_scope_ref: optional_ref(attrs, :operation_scope_ref),
      target_ref: optional_ref(attrs, :target_ref),
      attach_grant_ref: optional_ref(attrs, :attach_grant_ref),
      authority_decision_ref: optional_ref(attrs, :authority_decision_ref),
      redaction_ref: optional_ref(attrs, :redaction_ref),
      resource_ref: attrs |> AttrMap.fetch!(:resource_ref, @packet_name) |> ref!(:resource_ref),
      subject_ref: attrs |> AttrMap.fetch!(:subject_ref, @packet_name) |> ref!(:subject_ref),
      action: attrs |> AttrMap.fetch!(:action, @packet_name) |> string!(:action),
      policy_revision:
        attrs |> AttrMap.fetch!(:policy_revision, @packet_name) |> string!(:policy_revision),
      installation_revision:
        attrs
        |> AttrMap.fetch!(:installation_revision, @packet_name)
        |> non_neg_integer!(:installation_revision),
      activation_epoch:
        attrs
        |> AttrMap.fetch!(:activation_epoch, @packet_name)
        |> non_neg_integer!(:activation_epoch),
      boundary_class:
        attrs |> AttrMap.fetch!(:boundary_class, @packet_name) |> string!(:boundary_class),
      trust_profile:
        attrs |> AttrMap.fetch!(:trust_profile, @packet_name) |> string!(:trust_profile),
      approval_profile:
        attrs |> AttrMap.fetch!(:approval_profile, @packet_name) |> string!(:approval_profile),
      egress_profile:
        attrs |> AttrMap.fetch!(:egress_profile, @packet_name) |> string!(:egress_profile),
      workspace_profile:
        attrs |> AttrMap.fetch!(:workspace_profile, @packet_name) |> string!(:workspace_profile),
      resource_profile:
        attrs |> AttrMap.fetch!(:resource_profile, @packet_name) |> string!(:resource_profile),
      idempotency_key:
        attrs |> AttrMap.fetch!(:idempotency_key, @packet_name) |> string!(:idempotency_key),
      trace_id: attrs |> AttrMap.fetch!(:trace_id, @packet_name) |> string!(:trace_id),
      correlation_id:
        attrs |> AttrMap.fetch!(:correlation_id, @packet_name) |> string!(:correlation_id),
      release_manifest_ref:
        attrs
        |> AttrMap.fetch!(:release_manifest_ref, @packet_name)
        |> string!(:release_manifest_ref),
      decision_hash:
        attrs |> AttrMap.fetch!(:decision_hash, @packet_name) |> hash!(:decision_hash),
      canonical_json_hash:
        attrs |> AttrMap.fetch!(:canonical_json_hash, @packet_name) |> hash!(:canonical_json_hash),
      extensions: attrs |> AttrMap.fetch!(:extensions, @packet_name) |> extensions!(:extensions)
    }
  end

  defp normalize(%__MODULE__{} = packet) do
    {:ok, packet |> dump() |> build!()}
  rescue
    error in ArgumentError -> {:error, error}
  end

  defp optional_ref(attrs, key) do
    case AttrMap.get(attrs, key) do
      nil -> nil
      value -> ref!(value, key)
    end
  end

  defp optional_string(attrs, key) do
    case AttrMap.get(attrs, key) do
      nil -> nil
      value -> string!(value, key)
    end
  end

  defp validate_actor_pair!(nil, nil) do
    raise ArgumentError, "#{@packet_name} requires principal_ref or system_actor_ref"
  end

  defp validate_actor_pair!(_principal_ref, _system_actor_ref), do: :ok

  defp validate_literal!(value, expected, _field) when value == expected, do: value

  defp validate_literal!(value, expected, field) do
    raise ArgumentError, "#{@packet_name}.#{field} must be #{expected}, got: #{inspect(value)}"
  end

  defp ref!(value, field) when is_binary(value), do: string!(value, field)

  defp ref!(value, field) do
    normalized = CanonicalJson.normalize!(value)

    unless is_map(normalized) do
      raise ArgumentError, "#{@packet_name}.#{field} must be a non-empty string or JSON object"
    end

    normalized
  end

  defp string!(value, field) when is_binary(value) do
    if String.trim(value) == "" do
      raise ArgumentError, "#{@packet_name}.#{field} must be a non-empty string"
    end

    value
  end

  defp string!(value, field) do
    raise ArgumentError,
          "#{@packet_name}.#{field} must be a non-empty string, got: #{inspect(value)}"
  end

  defp non_neg_integer!(value, _field) when is_integer(value) and value >= 0, do: value

  defp non_neg_integer!(value, field) do
    raise ArgumentError,
          "#{@packet_name}.#{field} must be a non-negative integer, got: #{inspect(value)}"
  end

  defp hash!(value, field) when is_binary(value) do
    if lower_hex_64?(value) do
      value
    else
      raise ArgumentError, "#{@packet_name}.#{field} must be lowercase SHA-256 hex"
    end
  end

  defp hash!(value, field) do
    raise ArgumentError,
          "#{@packet_name}.#{field} must be lowercase SHA-256 hex, got: #{inspect(value)}"
  end

  defp lower_hex_64?(value) do
    byte_size(value) == 64 and
      value
      |> :binary.bin_to_list()
      |> Enum.all?(fn byte -> byte in ?0..?9 or byte in ?a..?f end)
  end

  defp extensions!(value, field) do
    normalized = CanonicalJson.normalize!(value)

    unless is_map(normalized) do
      raise ArgumentError, "#{@packet_name}.#{field} must normalize to a JSON object"
    end

    unknown_namespaces =
      normalized |> Map.keys() |> Enum.sort() |> Kernel.--(@extensions_namespaces)

    if unknown_namespaces != [] do
      raise ArgumentError,
            "#{@packet_name}.#{field} only allows #{inspect(@extensions_namespaces)} namespaces, got: " <>
              inspect(unknown_namespaces)
    end

    normalized
  end

  defp reject_nil_refs(payload) do
    payload
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp put_pending_hashes(attrs) do
    attrs
    |> Map.new()
    |> Map.put(:decision_hash, String.duplicate("0", 64))
    |> Map.put(:canonical_json_hash, String.duplicate("0", 64))
  end

  defp sha256(value) when is_binary(value) do
    :sha256
    |> :crypto.hash(value)
    |> Base.encode16(case: :lower)
  end
end
