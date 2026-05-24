defmodule Citadel.ContextAuthority.AuthorityRequest do
  @moduledoc """
  Ref-only request for authorizing one Context ABI packet use.
  """

  alias Citadel.ContractCore.Value

  @operations [:context_access, :route_policy, :promotion, :rollback]
  @payload_modes [:refs_only, :bounded_summary, :claim_check, :raw_payload]
  @redaction_classes [:public_safe, :operator_summary, :tenant_sensitive, :secret]
  @trust_classes [
    :operator_authored,
    :system_policy,
    :tenant_policy,
    :source_connector,
    :workflow_receipt,
    :model_generated_unverified,
    :model_generated_verified,
    :memory_promoted,
    :memory_candidate,
    :external_untrusted
  ]

  @required_fields [
    :tenant_ref,
    :actor_ref,
    :context_packet_ref,
    :model_class_allowlist,
    :route_policy_ref,
    :trace_ref
  ]

  @optional_fields [
    :operation,
    :payload_mode,
    :redaction_class,
    :trust_classes,
    :policy_expires_at,
    :authority_ref,
    :evidence_refs,
    :metadata
  ]

  @fields @required_fields ++ @optional_fields

  @enforce_keys @required_fields
  defstruct @fields

  @type operation :: :context_access | :route_policy | :promotion | :rollback
  @type payload_mode :: :refs_only | :bounded_summary | :claim_check | :raw_payload
  @type redaction_class :: :public_safe | :operator_summary | :tenant_sensitive | :secret

  @type t :: %__MODULE__{
          tenant_ref: String.t(),
          actor_ref: String.t(),
          context_packet_ref: String.t(),
          model_class_allowlist: [String.t()],
          route_policy_ref: String.t(),
          trace_ref: String.t(),
          operation: operation(),
          payload_mode: payload_mode(),
          redaction_class: redaction_class(),
          trust_classes: [atom()],
          policy_expires_at: DateTime.t() | nil,
          authority_ref: String.t() | nil,
          evidence_refs: [String.t()],
          metadata: map()
        }

  @spec operations() :: [operation()]
  def operations, do: @operations

  @spec payload_modes() :: [payload_mode()]
  def payload_modes, do: @payload_modes

  @spec redaction_classes() :: [redaction_class()]
  def redaction_classes, do: @redaction_classes

  @spec trust_classes() :: [atom()]
  def trust_classes, do: @trust_classes

  @spec new(t() | map() | keyword()) :: {:ok, t()} | {:error, Exception.t()}
  def new(%__MODULE__{} = request), do: request |> dump() |> new()

  def new(attrs) do
    {:ok, new!(attrs)}
  rescue
    error in ArgumentError -> {:error, error}
  end

  @spec new!(t() | map() | keyword()) :: t()
  def new!(%__MODULE__{} = request), do: request |> dump() |> new!()

  def new!(attrs) do
    attrs = Value.normalize_attrs!(attrs, "Citadel.ContextAuthority.AuthorityRequest", @fields)

    %__MODULE__{
      tenant_ref: required_string(attrs, :tenant_ref),
      actor_ref: required_string(attrs, :actor_ref),
      context_packet_ref: required_string(attrs, :context_packet_ref),
      model_class_allowlist: required_strings(attrs, :model_class_allowlist),
      route_policy_ref: required_string(attrs, :route_policy_ref),
      trace_ref: required_string(attrs, :trace_ref),
      operation: optional_enum(attrs, :operation, @operations, :context_access),
      payload_mode: optional_enum(attrs, :payload_mode, @payload_modes, :refs_only),
      redaction_class:
        optional_enum(attrs, :redaction_class, @redaction_classes, :tenant_sensitive),
      trust_classes: optional_enums(attrs, :trust_classes, @trust_classes),
      policy_expires_at: optional_datetime(attrs, :policy_expires_at),
      authority_ref: optional_string(attrs, :authority_ref),
      evidence_refs: optional_strings(attrs, :evidence_refs),
      metadata: optional_map(attrs, :metadata)
    }
  end

  @spec dump(t()) :: map()
  def dump(%__MODULE__{} = request) do
    %{
      tenant_ref: request.tenant_ref,
      actor_ref: request.actor_ref,
      context_packet_ref: request.context_packet_ref,
      model_class_allowlist: request.model_class_allowlist,
      route_policy_ref: request.route_policy_ref,
      trace_ref: request.trace_ref,
      operation: request.operation,
      payload_mode: request.payload_mode,
      redaction_class: request.redaction_class,
      trust_classes: request.trust_classes,
      policy_expires_at: datetime_to_iso8601(request.policy_expires_at),
      authority_ref: request.authority_ref,
      evidence_refs: request.evidence_refs,
      metadata: request.metadata
    }
  end

  defp required_string(attrs, field) do
    Value.required(attrs, field, "Citadel.ContextAuthority.AuthorityRequest", fn value ->
      Value.string!(value, "Citadel.ContextAuthority.AuthorityRequest.#{field}")
    end)
  end

  defp optional_string(attrs, field) do
    Value.optional(
      attrs,
      field,
      "Citadel.ContextAuthority.AuthorityRequest",
      fn value -> Value.string!(value, "Citadel.ContextAuthority.AuthorityRequest.#{field}") end,
      nil
    )
  end

  defp required_strings(attrs, field) do
    Value.required(attrs, field, "Citadel.ContextAuthority.AuthorityRequest", fn value ->
      Value.unique_strings!(value, "Citadel.ContextAuthority.AuthorityRequest.#{field}",
        allow_empty?: false
      )
    end)
  end

  defp optional_strings(attrs, field) do
    Value.optional(
      attrs,
      field,
      "Citadel.ContextAuthority.AuthorityRequest",
      fn value ->
        Value.unique_strings!(value, "Citadel.ContextAuthority.AuthorityRequest.#{field}")
      end,
      []
    )
  end

  defp optional_enum(attrs, field, allowed, default) do
    Value.optional(
      attrs,
      field,
      "Citadel.ContextAuthority.AuthorityRequest",
      fn value ->
        Value.enum!(value, allowed, "Citadel.ContextAuthority.AuthorityRequest.#{field}")
      end,
      default
    )
  end

  defp optional_enums(attrs, field, allowed) do
    Value.optional(
      attrs,
      field,
      "Citadel.ContextAuthority.AuthorityRequest",
      fn value ->
        Value.list!(
          value,
          "Citadel.ContextAuthority.AuthorityRequest.#{field}",
          &Value.enum!(&1, allowed, "Citadel.ContextAuthority.AuthorityRequest.#{field}")
        )
      end,
      []
    )
  end

  defp optional_datetime(attrs, field) do
    Value.optional(
      attrs,
      field,
      "Citadel.ContextAuthority.AuthorityRequest",
      fn value ->
        Value.datetime!(value, "Citadel.ContextAuthority.AuthorityRequest.#{field}")
      end,
      nil
    )
  end

  defp optional_map(attrs, field) do
    Value.optional(
      attrs,
      field,
      "Citadel.ContextAuthority.AuthorityRequest",
      fn value ->
        Value.json_object!(value, "Citadel.ContextAuthority.AuthorityRequest.#{field}")
      end,
      %{}
    )
  end

  defp datetime_to_iso8601(nil), do: nil
  defp datetime_to_iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
end
